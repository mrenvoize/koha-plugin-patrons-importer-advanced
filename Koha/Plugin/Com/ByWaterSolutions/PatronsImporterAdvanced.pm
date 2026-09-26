package Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Log qw(logaction);
use Koha::Config;
use Koha::Database;
use Koha::Email;
use Koha::Encryption;
use Koha::File::Transport;
use Koha::File::Transports;
use Koha::Patrons::Import;
use Koha::Patron::Attribute::Types;
use Koha::Patron::Attributes;
use Koha::Patron::Image;
use Koha::Patron::Images;
use Koha::TemplateUtils qw(process_tt);

use GD;
use Archive::Zip qw( :ERROR_CODES );
use Cwd          qw( realpath );
use File::Spec;

use Data::Dumper;
use File::Temp qw(tempdir tempfile);
use Storable qw(dclone);
use Text::CSV::Slurp;
use Try::Tiny;
use XML::Simple;
use XML::Simple qw( XMLin );
use YAML::XS qw(Load Dump);

use Digest::SHA qw(sha256_hex);
use JSON         qw(encode_json decode_json);
use POSIX        qw(strftime);

## Here we set our plugin version
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

our $metadata = {
    name            => 'Advanced Patrons Importer',
    author          => 'Kyle M Hall',
    date_authored   => '2024-06-12',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     =>
'Automate importing patron CSV files with column mapping and transformations',
};

# Limits for _import_photo/_import_photo_batch, matching Koha core Bug
# 43637's Koha::Patron::Image::Import (see the Phase 2 spec's "Forward
# compatibility" section) so a future swap to that class needs no data
# changes.
use constant PHOTO_MAX_FILE_SIZE      => 2_097_152;    # 2MB
use constant PHOTO_MAX_WIDTH          => 200;
use constant PHOTO_MAX_HEIGHT         => 300;
use constant PHOTO_IMAGE_EXTENSION_RE => qr/\.(?:jpe?g|png|gif|xpm)$/i;
use constant PHOTO_MAX_ZIP_MEMBERS    => 1000;

=head3 new

=cut

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

=head3 configure

=cut

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        if ( $cgi->param('sync') ) {
            $self->cronjob_nightly( { send_sync_report => 1 } );
            $template->param( sync_report_ran => 1, );
        }

        try {
            ## Grab the values we already have for our settings, if any exist
            $template->param(
                configuration => Koha::Encryption->new->decrypt_hex(
                    $self->retrieve_data('configuration')
                )
            );
        };

        if ( $cgi->param('test') ) {
            my $data = $self->get_configuration();

            my @results;
            foreach my $job (@$data) {
                unless ( $job->{file_transport_id} ) {
                    push(
                        @results,
                        {
                            job   => $job,
                            ok    => 0,
                            error => 'Job has no file_transport_id configured - it will be skipped by the importer',
                        }
                    );
                    next;
                }
                my $result = $self->_test_job_transport($job);
                push( @results, { job => $job, %$result } );
            }

            $template->param( results => \@results, test_completed => 1 );
        }

        $self->output_html( $template->output() );
    }
    else {
        # Log previous configuration, redact sftp passwords
        my $current_configuration = eval { $self->get_configuration() };
        my $current_yaml          = _redacted_yaml($current_configuration);
        my $new_configuration     = eval {
            YAML::XS::Load( Encode::encode_utf8( scalar $cgi->param('configuration') ) );
        };
        my $new_yaml = _redacted_yaml($new_configuration);
        logaction("PatronsImporterAdvanced", "ChangeConfiguration", "", $new_yaml, "", $current_yaml);


        my $encrypted =
          Koha::Encryption->new->encrypt_hex( $cgi->param('configuration') );

        $self->store_data( { configuration => $encrypted } );

        C4::Log::logaction( 'SYSTEMPREFERENCE', 'MODIFY', undef,
            "PatronsImporterAdvanced: $encrypted" );

        $self->go_home();
    }
}

sub _redacted_yaml {
    my ($configuration) = @_;

    return "" unless $configuration;

    my $redacted = dclone($configuration);
    $redacted = [$redacted] unless ref $redacted eq 'ARRAY';
    foreach my $job (@$redacted) {
        $job->{sftp}->{password} = "*****" if ref $job eq 'HASH' && $job->{sftp};
    }

    return YAML::XS::Dump($redacted);
}

=head3 _migrate_job_transport

Given a single job hashref, if it has a legacy C<sftp>, C<local>, or
C<file_transport> block and no C<file_transport_id> yet, point the job at
the equivalent C<file_transport_id> and remove the legacy block. C<sftp>/
C<local> blocks get a brand new C<Koha::File::Transport> row created for
them; a C<file_transport> block already references an existing one (by id
or by name), so it's simply resolved and pointed to directly. Idempotent: a
job that already has C<file_transport_id>, or has none of the three legacy
blocks, is returned unchanged.

=cut

sub _migrate_job_transport {
    my ( $self, $job ) = @_;

    return $job if $job->{file_transport_id};

    if ( my $ft = $job->{file_transport} ) {
        my $transport;
        if ( $ft->{id} ) {
            $transport = Koha::File::Transports->find( $ft->{id} );
            die "Patrons Importer - MIGRATION ERROR: No file transport found with id $ft->{id}"
              unless $transport;
        }
        elsif ( $ft->{name} ) {
            my $transports = Koha::File::Transports->search( { name => $ft->{name} } );
            my $count       = $transports->count;
            die "Patrons Importer - MIGRATION ERROR: No file transport found named '$ft->{name}'"
              unless $count;
            die "Patrons Importer - MIGRATION ERROR: $count file transports are named '$ft->{name}', use id instead"
              if $count > 1;
            $transport = $transports->next;
        }
        else {
            die "Patrons Importer - MIGRATION ERROR: file_transport requires an id or a name";
        }

        $job->{file_transport_id} = $transport->file_transport_id;
        $job->{filename}          = $ft->{filename};

        # The transport's own download_directory is never TT-rendered, but a
        # job's `path` override always is - so any directory override here,
        # markup or not, is safe to carry over as `path` unconditionally.
        $job->{path} = $ft->{directory} if defined $ft->{directory} && length $ft->{directory};

        delete $job->{file_transport};
    }
    elsif ( my $sftp = $job->{sftp} ) {
        my $transport = Koha::File::Transport->new(
            {
                name               => "PatronsImporterAdvanced: " . ( $job->{name} // 'unnamed job' ),
                transport          => 'sftp',
                host               => $sftp->{host},
                port               => $sftp->{port} || 22,
                user_name          => $sftp->{username},
                password           => $sftp->{password},
                auth_mode          => 'password',
                download_directory => $sftp->{directory},
            }
        )->store;

        $job->{file_transport_id} = $transport->id;
        $job->{filename}          = $sftp->{filename};
        delete $job->{sftp};
    }
    elsif ( my $local = $job->{local} ) {

        # Koha::File::Transport never runs Template Toolkit rendering on
        # download_directory, but the job-level `path` override does get
        # process_tt'd on every fetch - so a directory containing TT markup
        # must migrate to the job's own `path` key to keep working.
        my $directory        = $local->{directory};
        my $directory_has_tt = defined $directory && $directory =~ /\[%/;

        my $transport = Koha::File::Transport->new(
            {
                name               => "PatronsImporterAdvanced: " . ( $job->{name} // 'unnamed job' ),
                transport          => 'local',
                auth_mode          => 'noauth',
                download_directory => $directory_has_tt ? undef : $directory,
            }
        )->store;

        $job->{file_transport_id} = $transport->id;
        $job->{filename}          = $local->{filename};
        $job->{path}              = $directory if $directory_has_tt;
        delete $job->{local};
    }

    return $job;
}

=head3 _test_job_transport

Test the configured file transport for a single job. Returns a hashref with
C<ok> (boolean) and, on failure, an C<error> string built from the
transport's recorded messages.

=cut

sub _test_job_transport {
    my ( $self, $job ) = @_;

    my $transport = Koha::File::Transports->find( $job->{file_transport_id} );
    return { ok => 0, error => "No such file_transport_id: $job->{file_transport_id}" } unless $transport;

    # Some Koha versions' SFTP transport dies rather than returning false on
    # failure (e.g. Koha 25.11, missing JSON import) - catch that too, not
    # just a false return, so a bad connection is reported per-job instead
    # of crashing the whole "Test connections" button.
    my $ok = try { $transport->test_connection } catch { 0 };
    return { ok => 1 } if $ok;

    my $error = join( '; ', map { $_->message } @{ $transport->object_messages } );
    return { ok => 0, error => $error || 'Unknown error' };
}

=head3 get_configuration

=cut

sub get_configuration {
    my ($self) = @_;

    my $configuration = Koha::Encryption->new->decrypt_hex(
        $self->retrieve_data('configuration') );

    my $data = eval { YAML::XS::Load( Encode::encode_utf8($configuration) ); };
    if ($@) {
        die "CRITICAL ERROR: Unable to parse yaml `$configuration` : $@";
    }

    return $data;
}

=head3 cronjob_nightly

=cut

sub cronjob_nightly {
    my ( $self, $p ) = @_;

    my $data = $self->get_configuration();

    # Load transformation subroutines from kaho-conf.xml
    my $conf_file = Koha::Config->guess_koha_conf;
    my $xml       = XMLin(
        $conf_file,
        ForceArray    => 0,
        SuppressEmpty => undef,
    );

    my $koha_conf_data = $xml->{config}->{patrons_importer_advanced};
    my $transformers   = $koha_conf_data->{transformers};
    if ($transformers) {
        foreach my $sub_name ( keys %$transformers ) {
            my $code   = $transformers->{$sub_name};
            my $subref = eval $code;
            die "ERROR IN $sub_name: $@" if $@;
            $transformers->{$sub_name} = $subref;
        }
    }

    foreach my $job (@$data) {
        my $lock_name;
        my $lock_acquired = 0;
        try {
            next if $job->{disable};

            my $debug = $job->{debug} || 0;

            say "Working on job: $job->{name}" if $debug;

            my $run_on_dow = $job->{run_on_dow};
            if ( defined $run_on_dow ) {
                my $current_dow   = (localtime)[6];
                my $is_day_to_run = index( $run_on_dow, $current_dow ) != -1;
                if ($is_day_to_run) {
                    say "Running import, $current_dow is listed in $run_on_dow"
                      if $debug >= 1;
                }
                else {
                    say "Skipping import, $current_dow is listed in $run_on_dow"
                      if $debug >= 1;
                    next;
                }
            }

            # Guard against overlapping runs of the same job: frequent
            # scheduling means two cron ticks can otherwise both pass the
            # content-hash check before either records its run. MySQL user
            # lock names are limited to 64 characters, so hash longer ones.
            $lock_name = "PatronsImporterAdvanced:" . ( $job->{name} // 'unnamed job' );
            $lock_name = sha256_hex($lock_name) if length($lock_name) > 64;
            ($lock_acquired) =
              C4::Context->dbh->selectrow_array( q{SELECT GET_LOCK(?, 0)}, undef, $lock_name );
            unless ($lock_acquired) {
                say "JOB $job->{name} IS ALREADY RUNNING IN ANOTHER PROCESS, SKIPPING THIS RUN";
                next;
            }

            my $type = $job->{type} // 'record';
            if ( $type eq 'photo' ) {
                $self->_run_photo_job($job);
            }
            else {
                $self->_run_record_job( $job, $transformers );
            }

        }
        catch {
            say "JOB $job->{name} FAILED WITH THE ERROR: $_";
        }
        finally {
            # Always release the lock - success, failure, or skip partway
            # through - but never release one we did not acquire.
            C4::Context->dbh->selectrow_array( q{SELECT RELEASE_LOCK(?)}, undef, $lock_name )
              if $lock_acquired;
        };
    }
}

=head3 _run_record_job

Run a single C<type: record> (CSV patron import) job: download its source
file via the configured transport, apply column mapping/transformation,
skip re-importing unchanged content, hand the result to
C<Koha::Patrons::Import>, and record/report the outcome.

=cut

sub _run_record_job {
    my ( $self, $job, $transformers ) = @_;

    my $debug   = $job->{debug}   || 0;
    my $verbose = $job->{verbose} || 0;

    my $transport_id = $job->{file_transport_id};
    unless ($transport_id) {
        say "JOB $job->{name} HAS NO file_transport_id, SKIPPING";
        return;
    }

    my $transport = Koha::File::Transports->find($transport_id);
    unless ($transport) {
        say "JOB $job->{name} REFERENCES UNKNOWN file_transport_id $transport_id, SKIPPING";
        return;
    }

    my $filename       = process_tt( $job->{filename} );
    my $directory      = tempdir( CLEANUP => 1 );
    my $local_path     = "$directory/$filename";
    my $download_opts = $job->{path} ? { path => process_tt( $job->{path} ) } : {};

    $debug && say "Downloading '$filename' via transport #$transport_id to '$local_path'";

    # Some Koha versions' SFTP transport dies rather than returning
    # false on failure (e.g. Koha 25.11, missing JSON import) -
    # catch that too, not just a false return, so either failure
    # mode produces the same informative error below.
    my $downloaded = try { $transport->download_file( $filename, $local_path, $download_opts ) } catch { 0 };
    $downloaded
      or die "Patrons Importer - TRANSPORT ERROR: download failed for $filename: "
      . join( '; ', map { $_->message } @{ $transport->object_messages } );

    my $filepath = $local_path;

    # Write a header if needed
    if ( my $header = $job->{file}->{header} ) {
        my ( $new_tmp_fh, $new_tmp_filename ) = tempfile();
        binmode( $new_tmp_fh, ":utf8" );

        open my $new, '>:encoding(UTF-8)', $new_tmp_filename
          or die "$new_tmp_filename: $!";
        open my $old, '<:encoding(UTF-8)', $filepath
          or die "$filepath: $!";

        print {$new} "$header\n";
        print {$new} $_ while <$old>;
        close $new;

        $filepath = $new_tmp_filename;
    }

    my $content_hash = $self->_content_hash($filepath);
    unless ( $self->_job_should_run( $job->{name}, $content_hash ) ) {
        say "No changes since last run for job $job->{name}, skipping" if $debug || $verbose;
        return;
    }

    my $options = $job->{csv_options} || {};
    my $inputs = Text::CSV::Slurp->load( file => $filepath, %$options );

    my @output_data;
    foreach my $input (@$inputs) {
        $debug && say "WORKING ON " . Data::Dumper::Dumper($input);

        if ( $input->{disabled} ) {
            say "DISABLED, SKIPPING...";
            next;
        }

        my $skip = 0;
        foreach my $input_column ( keys %{ $job->{skip_incoming} } ) {
            my $values = $job->{skip_incoming}->{$input_column};
            foreach my $value (@$values) {
                if ( defined $input->{$input_column}
                    && $input->{$input_column} eq $value )
                {
                    $debug
                      && say
"SKIPPING: Row has column '$input_column' value of $value, skipping!";
                    $skip = 1;
                    last;
                }
            }
        }
        next if $skip;

        my $output = {};
        my $stash  = {};

        my $columns = $job->{columns};
        foreach my $column (@$columns) {
            my $output_column = $column->{output};
            say "NO OUPUT SPECIFIED FOR "
              . Data::Dumper::Dumper($column)
              unless $output;

            if ( defined $column->{static} ) {
                my $static_value = $column->{static};
                $output->{$output_column} = $static_value;
            }
            elsif ( defined $column->{input} ) {
                my $input_column = $column->{input};
                my $value        = $input->{$input_column} // q{};
                my $prefix       = $column->{prefix}       // q{};
                my $padding      = $column->{padding}      // q{};
                my $length       = $column->{length}       // 0;

                my $padding_length =
                  $length - length($prefix) - length($value);
                $padding_length = 0 if $padding_length < 0;
                $padding        = $padding x $padding_length;

                $value = $prefix . $padding . $value;
                $output->{$output_column} = $value;
            }
            elsif ( defined $column->{mapping} ) {
                my $mapping = $column->{mapping};
                my $source  = $mapping->{source};
                my $map     = $mapping->{map};

                my $input_value = $input->{$source};
                my $value       = $map->{$input_value};
                $output->{$output_column} = $value;
            }
            elsif ( defined $column->{transformer} ) {
                my $sub_name = $column->{transformer};
                my $sub      = $transformers->{$sub_name};
                die "NO TRANSFORMER NAMED $sub_name DEFINED"
                  unless $sub;

                try {
                    &$sub( $input, $output, $stash, $job );
                }
                catch {
                    warn
"Call to transformer $sub_name failed with errors: $_";
                };
            }
        }

        $debug && say "OUTPUT: " . Data::Dumper::Dumper($output);

        if ( $job->{delete_incoming} ) {
            my $criteria = $job->{delete_incoming};

            my $delete = 0;

            foreach my $c (@$criteria) {
                my $field      = $c->{field};
                my $value      = $c->{value};
                my $comparison = $c->{comparison};

                next
                  unless defined($field)
                  && defined($value)
                  && defined($comparison);

                if ( $comparison eq 'equals' ) {
                    $delete = 1
                      if defined( $output->{$field} )
                      && $output->{$field} eq $value;
                }
                elsif ( $comparison eq 'not_equals' ) {
                    $delete = 1
                      if defined( $output->{$field} )
                      && $output->{$field} ne $value;
                }

                say "DELETING $output->{cardnumber} BECAUSE "
                  . Data::Dumper::Dumper($c)
                  if $delete && $verbose;

                if ($delete) {
                    delete_if_found( $output, $job );
                }
                else {
                    push( @output_data, $output );
                }
            }

            delete_if_found( $output, $job ) if $delete;
        }
        else {
            push( @output_data, $output );
        }
    }

    my ( $tmp_fh, $tmp_filename ) = tempfile();
    binmode( $tmp_fh, ":utf8" );
    my $csv = Text::CSV::Slurp->create( input => \@output_data );
    print $tmp_fh $csv;
    close $tmp_fh;

    # Reopen file handle for reading
    my $handle;
    open( $handle, "<:encoding(UTF-8)", $tmp_filename ) or die $!;

    my $Import = Koha::Patrons::Import->new();
    my $params = $job->{parameters};
    my $return = $Import->import_patrons(
        {
            file => $handle,
            %$params,
        }
    );

    my $feedback    = $return->{feedback};
    my $errors      = $return->{errors};
    my $imported    = $return->{imported};
    my $overwritten = $return->{overwritten};
    my $alreadyindb = $return->{already_in_db};
    my $invalid     = $return->{invalid};
    my $total = $imported + $alreadyindb + $invalid + $overwritten;

    if ($verbose) {
        say q{};
        say "Import complete:";
        say "Imported:    $imported";
        say "Overwritten: $overwritten";
        say "Skipped:     $alreadyindb";
        say "Invalid:     $invalid";
        say "Total:       $total";
        say q{};
    }

    $self->_record_job_run(
        $job->{name}, $content_hash,
        { imported => $imported, overwritten => $overwritten, already_in_db => $alreadyindb, invalid => $invalid }
    );

    if ( my $email_conf = $job->{email_results} ) {

        $email_conf->{text_body} = qq{
Import complete for $job->{name}:
Imported:    $imported
Overwritten: $overwritten
Skipped:     $alreadyindb
Invalid:     $invalid
Total:       $total
        };

        my $email = Koha::Email->create($email_conf);

        try {
            $email->send_or_die();
        }
        catch {
            warn "ERROR: Failed to send email for job $job->{name}: $_";
        }
    }

    if ( $verbose > 1 ) {
        say "Errors:";
        say Data::Dumper::Dumper($errors);
    }

    if ( $verbose > 2 ) {
        say "Feedback:";
        say Data::Dumper::Dumper($feedback);
    }

    if ( $job->{post_import_transformer} ) {
        my $sub_name = $job->{post_import_transformer};
        my $sub      = $transformers->{$sub_name};
        die "NO TRANSFORMER NAMED $sub_name DEFINED"
          unless $sub;

        try {
            &$sub( \@output_data, $job );
        }
        catch {
            warn "Call to transformer $sub_name failed with errors: $_";
        };
    }
}

=head3 _resolve_photo_patron

Resolve a patron from a matchpoint field name ("cardnumber", "userid", or
"patron_attribute_<code>") and an identifier value. Mirrors Koha core Bug
43637's C<Koha::Patron::Image::Import::_resolve_patron> (independent
implementation, same algorithm - see the Phase 2 spec's "Forward
compatibility" section). Returns a C<Koha::Patron> or undef if nothing
matches.

=cut

sub _resolve_photo_patron {
    my ( $self, $matchpoint, $identifier ) = @_;

    return unless defined $identifier && length $identifier;

    return Koha::Patrons->find( { $matchpoint => $identifier } )
      if $matchpoint eq 'cardnumber' || $matchpoint eq 'userid';

    my ($code) = $matchpoint =~ /^patron_attribute_(.+)$/;
    return unless $code;

    my $attribute_type = Koha::Patron::Attribute::Types->find($code);
    return unless $attribute_type && $attribute_type->unique_id;

    my @borrowernumbers =
      Koha::Patron::Attributes->search( { code => $code, attribute => $identifier } )->get_column('borrowernumber');
    return unless @borrowernumbers == 1;

    return Koha::Patrons->find( $borrowernumbers[0] );
}

=head3 _import_photo

Validate, resize if needed, convert to PNG, and store an open filehandle
(positioned at the start) as the patron image for whichever patron
C<matchpoint>/C<identifier> resolves to. C<matchpoint> is one of
"cardnumber", "userid", or "patron_attribute_<code>". If C<dry_run> is
true, resolves and validates the image but does not store it.

Returns C<{ success => 1 }> on success, or C<{ error => $code }> on
failure: C<OVRSIZ> (over 2MB), C<CORERR> (GD could not read the image),
C<PATRON_NOT_FOUND>, or C<DBERR> (storing the image failed).

=cut

sub _import_photo {
    my ( $self, $args ) = @_;
    my ( $fh, $identifier, $matchpoint, $dry_run ) = @{$args}{qw( file identifier matchpoint dry_run )};

    my $size = -s $fh;
    return { error => 'OVRSIZ' } if $size > PHOTO_MAX_FILE_SIZE;

    my $srcimage = eval { GD::Image->new($fh) };
    return { error => 'CORERR' } unless defined $srcimage;

    my $patron = $self->_resolve_photo_patron( $matchpoint, $identifier );
    return { error => 'PATRON_NOT_FOUND' } unless $patron;

    my $imgfile = $self->_photo_to_png($srcimage);

    if ($dry_run) {
        say "DRY RUN: would store image for $matchpoint => $identifier (borrowernumber "
          . $patron->borrowernumber . ")";
        return { success => 1 };
    }

    my $image = $patron->image;
    $image ||= Koha::Patron::Image->new( { borrowernumber => $patron->borrowernumber } );
    $image->set( { mimetype => 'image/png', imagefile => $imgfile } );

    my $stored = eval { $image->store };
    return { error => 'DBERR' } if $@ || !$stored;

    return { success => 1 };
}

=head3 _photo_to_png

Convert a GD::Image to PNG bytes, resizing it first if either dimension
exceeds 200x300, preserving aspect ratio by scaling to whichever of the
two ratios (width or height) is smaller, so the result always fits within
the bounding box.

=cut

sub _photo_to_png {
    my ( $self, $srcimage ) = @_;

    my ( $width, $height ) = $srcimage->getBounds();
    return $srcimage->png() unless $width > PHOTO_MAX_WIDTH || $height > PHOTO_MAX_HEIGHT;

    my $width_ratio  = PHOTO_MAX_WIDTH / $width;
    my $height_ratio = PHOTO_MAX_HEIGHT / $height;
    my $scale        = $width_ratio < $height_ratio ? $width_ratio : $height_ratio;

    my $new_width  = sprintf( '%.0f', $width * $scale );
    my $new_height = sprintf( '%.0f', $height * $scale );

    my $resized = GD::Image->new( $new_width, $new_height, 1 );
    $resized->copyResampled( $srcimage, 0, 0, 0, 0, $new_width, $new_height, $width, $height );

    return $resized->png();
}

=head3 _is_safe_relative_path

Structural zip-slip guard: true if C<$path> is a relative path with no
".." component, no null byte, and is not an absolute path (unix "/..." or
windows "C:\..."). Independent implementation of the same check used by
C<Koha::ArticleRequest::ScanImport> and Koha core Bug 43637's
C<Koha::Patron::Image::Import> - see the Phase 2 spec's "Forward
compatibility" section.

=cut

sub _is_safe_relative_path {
    my ( $self, $path ) = @_;

    return 0 unless defined $path && length $path;
    return 0 if $path =~ /\0/;
    return 0 if $path =~ m{\A/};
    return 0 if $path =~ m{\A[A-Za-z]:[\\/]};

    for my $part ( split m{[\\/]+}, $path ) {
        next unless length $part;
        return 0 if $part eq '..';
    }

    return 1;
}

=head3 _check_photo_path_safe_and_exists

Validates that C<$filename> (as resolved relative to C<$extract_dir>)
cannot escape C<$extract_dir> - structurally via C<_is_safe_relative_path>,
then again via C<realpath> once the file is known to exist, to also catch
symlink-based escapes. Returns undef if safe, or an error code
(C<UNSAFE_PATH> or C<FILE_NOT_FOUND>) otherwise.

=cut

sub _check_photo_path_safe_and_exists {
    my ( $self, $extract_dir, $filename ) = @_;

    return 'UNSAFE_PATH' unless $self->_is_safe_relative_path($filename);

    my $candidate = File::Spec->catfile( $extract_dir, $filename );
    return 'FILE_NOT_FOUND' unless -f $candidate;

    my $real_dir  = realpath($extract_dir);
    my $real_file = realpath($candidate);
    return 'UNSAFE_PATH'
      unless defined $real_file
      && defined $real_dir
      && ( $real_file eq $real_dir || index( $real_file, "$real_dir/" ) == 0 );

    return;
}

=head3 _find_photo_image_files

Recursively collects every file under C<$dir> whose name matches
C<PHOTO_IMAGE_EXTENSION_RE>, returning each one's path relative to
C<$base>.

=cut

sub _find_photo_image_files {
    my ( $self, $dir, $base ) = @_;

    opendir( my $dh, $dir ) or return;
    my @entries = grep { !/^\.\.?$/ } readdir $dh;
    closedir $dh;

    my @found;
    for my $entry ( sort @entries ) {
        my $path = File::Spec->catfile( $dir, $entry );
        if ( -d $path ) {
            push @found, $self->_find_photo_image_files( $path, $base );
        }
        elsif ( $entry =~ PHOTO_IMAGE_EXTENSION_RE ) {
            push @found, File::Spec->abs2rel( $path, $base );
        }
    }
    return @found;
}

=head3 _find_photo_mapping_file

Recursively searches C<$dir> for a file named C<idlink.txt> or
C<datalink.txt> (case-insensitive), returning its full path, or undef if
none is found.

=cut

sub _find_photo_mapping_file {
    my ( $self, $dir ) = @_;

    opendir( my $dh, $dir ) or return;
    my @entries = readdir $dh;
    closedir $dh;

    for my $entry (@entries) {
        next if $entry =~ /^\.\.?$/;
        my $path = File::Spec->catfile( $dir, $entry );
        return $path if -f $path && $entry =~ /^(?:idlink|datalink)\.txt$/i;
        if ( -d $path ) {
            my $found = $self->_find_photo_mapping_file($path);
            return $found if $found;
        }
    }
    return;
}

=head3 _photo_rows_from_mapping_file

Parses C<$mapping_file> (tab- or comma-delimited "identifier,filename"
lines, delimiter sniffed per line) into a list of C<{ identifier,
filename }> hashrefs, or C<{ error => 'BAD_ROW' }> for a line that could
not be parsed.

=cut

sub _photo_rows_from_mapping_file {
    my ( $self, $mapping_file ) = @_;

    open my $fh, '<', $mapping_file or die "Unable to read $mapping_file: $!\n";
    my @lines = <$fh>;
    close $fh;

    my @rows;
    for my $line (@lines) {
        chomp $line;
        next unless length $line;

        my $delim = ( $line =~ /\t/ ) ? "\t" : ( $line =~ /,/ ) ? ',' : undef;
        unless ($delim) {
            push @rows, { error => 'BAD_ROW' };
            next;
        }

        my ( $identifier, $filename ) = split $delim, $line, 2;
        $identifier =~ s/[\"\r\n]//g if defined $identifier;
        $filename   =~ s/[\"\r\n]//g if defined $filename;

        unless ( defined $identifier && length $identifier && defined $filename && length $filename ) {
            push @rows, { error => 'BAD_ROW' };
            next;
        }

        push @rows, { identifier => $identifier, filename => $filename };
    }
    return @rows;
}

=head3 _photo_rows_from_filenames

Recursively finds every image file under C<$extract_dir> and returns a
C<{ identifier, filename }> hashref per file, where C<identifier> is the
file's own basename with its extension removed. Used when no mapping file
is present in the archive.

=cut

sub _photo_rows_from_filenames {
    my ( $self, $extract_dir ) = @_;

    my @rows;
    for my $relative ( $self->_find_photo_image_files( $extract_dir, $extract_dir ) ) {
        my ($basename) = $relative =~ m{([^/\\]+)$};
        ( my $stem = $basename ) =~ s/\.[^.]+$//;
        push @rows, { identifier => $stem, filename => $relative };
    }
    return @rows;
}

=head3 _import_photo_batch

Extracts the zip at C<$args-E<gt>{file}> (a local file path) and imports
every image it finds via C<_import_photo>: if the archive contains an
C<idlink.txt>/C<datalink.txt> mapping file, each row is resolved via that
mapping; otherwise every image file found is matched by its own filename's
stem against C<matchpoint> directly. Each row is processed in isolation -
one failure never aborts the rest of the batch. Rejects (without
extracting) an archive with more than C<PHOTO_MAX_ZIP_MEMBERS>
non-directory members. Returns C<{ imported => [...], errors => [...] }>.
Dies with a plain string only if the zip itself cannot be read.

=cut

sub _import_photo_batch {
    my ( $self, $args ) = @_;
    my ( $zip_path, $matchpoint, $dry_run ) = @{$args}{qw( file matchpoint dry_run )};

    my $zip = Archive::Zip->new;
    die "Unable to read zip file: $zip_path\n"
      unless $zip->read($zip_path) == Archive::Zip::AZ_OK;

    my @non_dir_members = grep { !$_->isDirectory } $zip->members;
    if ( @non_dir_members > PHOTO_MAX_ZIP_MEMBERS ) {
        return { imported => [], errors => [ { error => 'TOO_MANY_MEMBERS' } ] };
    }

    my $extract_dir = tempdir( CLEANUP => 1 );
    for my $member ( $zip->members ) {
        next if $member->isDirectory;
        my $name = $member->fileName;
        next unless $self->_is_safe_relative_path($name);
        $member->extractToFileNamed( File::Spec->catfile( $extract_dir, $name ) ) == Archive::Zip::AZ_OK
          or die "Unable to extract $name from $zip_path\n";
    }

    my $result       = { imported => [], errors => [] };
    my $mapping_file = $self->_find_photo_mapping_file($extract_dir);
    my @rows =
      $mapping_file
      ? $self->_photo_rows_from_mapping_file($mapping_file)
      : $self->_photo_rows_from_filenames($extract_dir);

    for my $row (@rows) {
        my ( $identifier, $filename ) = @{$row}{qw( identifier filename )};

        if ( $row->{error} ) {
            push @{ $result->{errors} }, { identifier => $identifier, filename => $filename, error => $row->{error} };
            next;
        }

        my $path_error = $self->_check_photo_path_safe_and_exists( $extract_dir, $filename );
        if ($path_error) {
            push @{ $result->{errors} }, { identifier => $identifier, filename => $filename, error => $path_error };
            next;
        }

        my $real_file = realpath( File::Spec->catfile( $extract_dir, $filename ) );
        my $outcome   = eval {
            open my $fh, '<', $real_file or die "Unable to read $real_file: $!\n";
            my $r = $self->_import_photo(
                { file => $fh, identifier => $identifier, matchpoint => $matchpoint, dry_run => $dry_run } );
            close $fh;
            $r;
        };
        if ($@) {
            push @{ $result->{errors} }, { identifier => $identifier, filename => $filename, error => 'UNEXPECTED_ERROR' };
            next;
        }
        if ( $outcome->{error} ) {
            push @{ $result->{errors} }, { identifier => $identifier, filename => $filename, error => $outcome->{error} };
        }
        else {
            push @{ $result->{imported} }, { identifier => $identifier, filename => $filename };
        }
    }

    return $result;
}

=head3 install

This is the 'install' method. Any database tables or other setup that should
be done when the plugin if first installed should be executed in this method.
The installation method should always return true if the installation succeeded
or false if it failed.

=cut

sub install() {
    my ( $self, $args ) = @_;

    return 1;
}

=head3 upgrade

This is the 'upgrade' method. It will be triggered when a newer version of a
plugin is installed over an existing older version of a plugin

=cut

sub upgrade {
    my ( $self, $args ) = @_;

    my $stored = $self->retrieve_data('configuration');
    return 1 unless $stored;

    my $jobs = eval { $self->get_configuration() };
    if ($@) {
        warn "PatronsImporterAdvanced: unable to read stored configuration during upgrade, "
          . "skipping transport migration: $@";
        return 1;
    }
    return 1 unless $jobs && ref $jobs eq 'ARRAY';

    my $before_yaml = _redacted_yaml($jobs);

    my $changed = 0;

    # Migrate every job's transport in a single transaction so a failure
    # partway through leaves neither orphan transport rows nor a config
    # that no longer matches the rows that were created.
    Koha::Database->new->schema->storage->txn_do(
        sub {
            foreach my $job (@$jobs) {
                next unless ref $job eq 'HASH';
                next unless $job->{sftp} || $job->{local} || $job->{file_transport};
                $self->_migrate_job_transport($job);
                $changed = 1;
            }
        }
    );

    if ($changed) {
        my $encrypted = Koha::Encryption->new->encrypt_hex( YAML::XS::Dump($jobs) );
        $self->store_data( { configuration => $encrypted } );
        logaction( "PatronsImporterAdvanced", "MigrateTransports", "", _redacted_yaml($jobs), "", $before_yaml );
    }

    return 1;
}

=head3 uninstall

This method will be run just before the plugin files are deleted
when a plugin is uninstalled. It is good practice to clean up
after ourselves!

=cut

sub uninstall {
    my ( $self, $args ) = @_;

    return 1;
}

sub delete_if_found {
    my ( $job, $output ) = @_;

    my $debug   = $job->{debug}   || 0;
    my $verbose = $job->{verbose} || 0;

    my $matchpoint = $job->{parameters}->{matchpoint};
    my $value      = $output->{$matchpoint};

    return unless $matchpoint && $value;

    my $patron =
      Koha::Patrons->find( { $matchpoint => $output->{$matchpoint} } );

    if ($patron) {
        say "MATCHING PATRON TO DELETE FOUND FOR "
          . "$matchpoint => $output->{$matchpoint}"
          if $verbose;
        $patron->move_to_deleted();
        $patron->delete();
    }
    else {
        say "NO MATCHING PATRON TO DELETE FOUND FOR "
          . "$matchpoint => $output->{$matchpoint}"
          if $verbose > 1;
    }
}

=head3 _content_hash

Return a SHA-256 hex digest of the given file's bytes.

=cut

sub _content_hash {
    my ( $self, $filepath ) = @_;

    open my $fh, '<:raw', $filepath or die "Cannot open $filepath: $!";
    local $/;
    my $content = <$fh>;
    close $fh;

    return sha256_hex($content);
}

=head3 _import_log

Return the stored per-job run history (a hashref keyed by job name), decoding
it from the plugin's C<import_log> data key. Defaults to an empty hashref.

=cut

sub _import_log {
    my ($self) = @_;

    my $stored = $self->retrieve_data('import_log');
    return {} unless $stored;

    my $data = eval { decode_json($stored) };
    return {} if $@;
    return $data // {};
}

=head3 _job_should_run

Given a job name and the content hash of its freshly downloaded input file,
return true if this content is new since the job's last recorded run (i.e.
the import should proceed), false if it's identical to last time (skip).

=cut

sub _job_should_run {
    my ( $self, $job_name, $content_hash ) = @_;

    my $log  = $self->_import_log;
    my $last = $log->{$job_name} or return 1;

    return ( $last->{last_hash} // '' ) ne $content_hash ? 1 : 0;
}

=head3 _record_job_run

Record that a job ran with the given content hash and result summary, for
future C<_job_should_run> comparisons.

=cut

sub _record_job_run {
    my ( $self, $job_name, $content_hash, $summary ) = @_;

    my $log = $self->_import_log;
    $log->{$job_name} = {
        last_hash   => $content_hash,
        last_run_at => strftime( '%Y-%m-%dT%H:%M:%S', localtime ),
        %$summary,
    };

    $self->store_data( { import_log => encode_json($log) } );
}

1;
