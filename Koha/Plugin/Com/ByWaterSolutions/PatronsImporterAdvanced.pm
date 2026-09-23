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
use Koha::Patrons::Import;
use Koha::TemplateUtils qw(process_tt);

use Data::Dumper;
use File::Temp qw(tempdir tempfile);
use Net::SFTP::Foreign;
use Text::CSV::Slurp;
use Try::Tiny;
use XML::Simple;
use XML::Simple qw( XMLin );
use YAML::XS qw(Load Dump);

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
                if ( $job->{sftp} ) {
                    my $error;
                    try {
                        my $sftp = $self->get_sftp($job);
                    }
                    catch {
                        $error = $_;
                    };
                    push( @results, { job => $job, error => $error } );
                }
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

    # The configuration is a list of jobs, each with its own sftp credentials
    $configuration = [$configuration] unless ref $configuration eq 'ARRAY';
    foreach my $job (@$configuration) {
        $job->{sftp}->{password} = "*****" if ref $job eq 'HASH' && $job->{sftp};
    }

    return YAML::XS::Dump($configuration);
}

sub get_sftp {
    my ( $self, $job ) = @_;
    my $sftp_host     = $job->{sftp}->{host};
    my $sftp_username = $job->{sftp}->{username};
    my $sftp_password = $job->{sftp}->{password};
    my $sftp_dir      = defined $job->{sftp}->{directory} ? process_tt( $job->{sftp}->{directory} ) : undef;
    my $sftp_port     = $job->{sftp}->{port};

    my $sftp = Net::SFTP::Foreign->new(
        host     => $sftp_host,
        user     => $sftp_username,
        port     => $sftp_port || 22,
        password => $sftp_password,
        timeout  => 5,                  # seconds
    );
    $sftp->die_on_error( "Patrons Importer - "
          . "SFTP ERROR: Unable to establish SFTP connection for "
          . Data::Dumper::Dumper( $job->{sftp} ) );

    $sftp->setcwd($sftp_dir)
      or die "Patrons Importer - SFTP ERROR: unable to change cwd: "
      . $sftp->error
      . " - for "
      . Data::Dumper::Dumper( $job->{sftp} );

    return $sftp;
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

            my $directory;
            my $filename;

            if ( $job->{local} ) {
                $directory = $job->{local}->{directory};
                $filename  = $job->{local}->{filename};
                $debug && say "Loading local file from $directory/$filename";
            }
            elsif ( $job->{sftp} ) {
                $directory = tempdir( CLEANUP => 1 );
                $filename  = process_tt( $job->{sftp}->{filename} // q{} );

                my $sftp_dir = defined $job->{sftp}->{directory} ? process_tt( $job->{sftp}->{directory} ) : undef;

                my $sftp = $self->get_sftp($job);

                $debug
                  && say qq{Downloading '$sftp_dir/$filename' }
                  . qq{via SFTP to '$directory/$filename'};

                $sftp->get( "$sftp_dir/$filename", "$directory/$filename" )
                  or die
"Patrons Importer - SFTP ERROR: get failed for $sftp_dir/$filename :"
                  . $sftp->error;
            }

            my $filepath = process_tt("$directory/$filename");

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

1;
