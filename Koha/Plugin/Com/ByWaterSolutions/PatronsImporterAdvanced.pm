package Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Log qw(logaction);
use Koha::Config;
use Koha::Email;
use Koha::Encryption;
use Koha::File::Transport;
use Koha::File::Transports;
use Koha::Patrons::Import;
use Koha::TemplateUtils qw(process_tt);

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
                next unless $job->{file_transport_id};
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

Given a single job hashref, if it has a legacy C<sftp> or C<local> block and
no C<file_transport_id> yet, create an equivalent C<Koha::File::Transport>
row, point the job at it via C<file_transport_id>, and remove the legacy
block. Idempotent: a job that already has C<file_transport_id>, or has
neither block, is returned unchanged.

=cut

sub _migrate_job_transport {
    my ( $self, $job ) = @_;

    return $job if $job->{file_transport_id};

    if ( my $sftp = $job->{sftp} ) {
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
        my $transport = Koha::File::Transport->new(
            {
                name               => "PatronsImporterAdvanced: " . ( $job->{name} // 'unnamed job' ),
                transport          => 'local',
                auth_mode          => 'noauth',
                download_directory => $local->{directory},
            }
        )->store;

        $job->{file_transport_id} = $transport->id;
        $job->{filename}          = $local->{filename};
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

    return { ok => 1 } if $transport->test_connection;

    my $error = join( '; ', map { $_->message } @{ $transport->object_messages } );
    return { ok => 0, error => $error || 'Unknown error' };
}

=head3 get_file_transport

Returns the Koha::File::Transport referenced by a job's 'file_transport' block,
connected and positioned in the job's directory. Dies if the transport can't be
found or connected to, or if the directory can't be changed to.

=cut

sub get_file_transport {
    my ( $self, $job ) = @_;
    my $conf = $job->{file_transport};

    die "Patrons Importer - FILE TRANSPORT ERROR: file_transport requires a filename"
      unless ref $conf eq 'HASH' && defined $conf->{filename} && length $conf->{filename};

    my $transport;
    if ( $conf->{id} ) {
        $transport = Koha::File::Transports->find( $conf->{id} );
        die "Patrons Importer - FILE TRANSPORT ERROR: No file transport found with id $conf->{id}"
          unless $transport;
    }
    elsif ( $conf->{name} ) {
        my $transports = Koha::File::Transports->search( { name => $conf->{name} } );
        my $count      = $transports->count;
        die "Patrons Importer - FILE TRANSPORT ERROR: No file transport found named '$conf->{name}'"
          unless $count;
        die "Patrons Importer - FILE TRANSPORT ERROR: $count file transports are named '$conf->{name}', use id instead"
          if $count > 1;
        $transport = $transports->next;
    }
    else {
        die "Patrons Importer - FILE TRANSPORT ERROR: file_transport requires an id or a name";
    }

    _file_transport_op( $transport, 'connect', sub { $transport->connect } );

    # The job's directory overrides the transport's download directory
    my $directory =
      ( defined $conf->{directory} && length $conf->{directory} )
      ? process_tt( $conf->{directory} )
      : $transport->download_directory;

    if ($directory) {
        _file_transport_op( $transport, "change directory to '$directory'",
            sub { $transport->change_directory($directory) } );
    }

    return $transport;
}

# Koha 25.11's SFTP transport dies ( missing JSON import ) instead of returning false when
# an operation fails, but it records the real error on the object first. So run every
# transport operation in a try block and build the message from the object's error messages.
sub _file_transport_op {
    my ( $transport, $description, $code ) = @_;

    my $exception;
    my $ok = try { $code->() } catch { $exception = $_; 0 };
    return 1 if $ok;

    my $label = sprintf( "'%s' ( #%s, %s://%s )",
        $transport->name, $transport->id, $transport->transport, $transport->host );
    my $reason = _file_transport_errors($transport);
    $reason .= " ( exception: $exception )" if $exception;

    die "Patrons Importer - FILE TRANSPORT ERROR: $description failed for file transport $label: $reason";
}

sub _file_transport_errors {
    my ($transport) = @_;

    my @errors = map {
        my $payload = $_->payload || {};
        $_->message . ': ' . ( $payload->{error} // 'unknown error' );
    } grep { $_->type eq 'error' } @{ $transport->object_messages };

    return join( '; ', @errors ) || 'unknown error';
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

    my $Import = Koha::Patrons::Import->new();

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
        try {
            next if $job->{disable};

            my $debug   = $job->{debug}   || 0;
            my $verbose = $job->{verbose} || 0;

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

            my $transport_id = $job->{file_transport_id};
            unless ($transport_id) {
                say "JOB $job->{name} HAS NO file_transport_id, SKIPPING" if $debug;
                next;
            }

            my $transport = Koha::File::Transports->find($transport_id);
            unless ($transport) {
                say "JOB $job->{name} REFERENCES UNKNOWN file_transport_id $transport_id, SKIPPING" if $debug;
                next;
            }

            my $filename    = process_tt( $job->{filename} );
            my $directory   = tempdir();
            my $local_path  = "$directory/$filename";
            my $download_opts = $job->{path} ? { path => process_tt( $job->{path} ) } : {};

            $debug && say "Downloading '$filename' via transport #$transport_id to '$local_path'";

            $transport->download_file( $filename, $local_path, $download_opts )
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
                next;
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
        catch {
            say "JOB $job->{name} FAILED WITH THE ERROR: $_";
        };
    }
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

    my $jobs = eval { $self->get_configuration() };
    return 1 unless $jobs && ref $jobs eq 'ARRAY';

    my $before_yaml = _redacted_yaml($jobs);

    my $changed = 0;
    foreach my $job (@$jobs) {
        next unless ref $job eq 'HASH';
        next unless $job->{sftp} || $job->{local};
        $self->_migrate_job_transport($job);
        $changed = 1;
    }

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
