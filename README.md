# Advanced Patrons Importer plugin for Koha

This plugin will automatically download patron CSV files and import them into Koha.
It can support unlimited files with different configurations and allows for renaming columns, mapping data and transformations via custom subroutines.

## Annotated configuration
```yaml
---
- name: EXAMPLE # Everything can have a name label, it doesn't actually do anything but can be helpful to have
  disable: 0    # Set to 1 to disable this job
  run_on_dow: 1,2,3,4,5 # Sunday (0) through Saturday (6), leave out for daily. List all day numbers separated by commas
  debug: 0      # Enable debugging for development
  verbose: 3    # Gives more verbose output from the Koha patron import process
  post_import_transformer: my_post_import_transformer # called after the import for a given job is completed
  file_transport_id: 3 # References a server configured under Koha's Administration > File transports (admin/file_transports.pl).
                        # Works for SFTP, FTP, or a purely local directory - create the transport there first, note its ID, and reference it here.
  filename: myfile.txt # Can be template toolkit markup, e.g. `"[% USE date %]CCC_STUDENTS_[% date.format(date.now, '%Y%m%d') %].csv"`
  path: /my/dir         # Optional. Overrides the transport's own configured directory for this job only. Can be template toolkit markup.
  file: # If the file you are ingesting has no header, you can inject one
    header: Last Name|First Name|Middle Name|Date of Birth|Level|Email|Phone|Address 1|Address 2|City|State|Zip|Enrollment Status
  parameters:   # These values will be passed directly to Koha::Patrons::Import::import_patrons, along with the file generated
    matchpoint: cardnumber
    preserve_extended_attributes: 1
    defaults:
      dateexpiry: 2099-01-01
      privacy: 1
    preserve_fields:
      - dateenrolled
      - password_expiration_date
      - fax
    overwrite_cardnumber: 1
    overwrite_passwords: 0
    update_dateexpiry: 1
    update_dateexpiry_from_today: 1
    update_dateexpiry_from_existing: 0
    send_welcome: 0
    dry_run: 0
  csv_options:  # These values will be passed to Text::CSV
    sep_char: "\t"
  delete_incoming: # If existing patron matches the matchpoint criteria and the incoming data ( after transformations ) matches any of the delete_incoming criteria the patron will be deleted
     - field: "sort1"
       value: "1"
       comparison: "equals"
     - field: "sort2"
       value: "1"
       comparison: "not_equals"
  columns:      # These are the output file column definitions
    - output: branchcode # Static output will just put the "static" value in the column
      static: ERU
    - output: surname    # Input will read the input column from the input file and place that value in the specified output column
      input: "Last Name" # essentially just renaming the column
      prefix: 1234       # Prepend the input column value with this value
      padding: "0"       # Character that should be used to pad the gap between the prefix and input if a minimum length is set
      length: 14         # Minimum length the input should be. Value will be padded between the prefix and value if it does not meet this length
    - name: Phone Number
      transformer: myTransformer  # Transformer will execute a custom perl subroutine defined in the koha conf file
    - output: categorycode  # Mapping allows for the transformation of one set of enumerated data to a different set of unumerated data
      mapping:
        source: studentgrade # The input file column to use as the lookup key
        map:
          "1": GRADESCHOOL
          "7": MIDDLESCHOOL
          "12": HIGHSCHOOL
          K: GRADESCHOOL
  skip_incoming: # If the incoming file row has a column with this name and a matching value, that row will not be imported as a patron:
    "Some Column":
      - "9"
      - "71"
      - "106"
  skip_incoming: # If the incoming file row has a column with this name and a matching value, that row will not be imported as a patron:
  send_email: # Optional, email results
    subject: Your library's import results
    from: me@example.com
    to: you@example.com
    cc: him@example.com
    bcc: her@example.com
    reply_to: them@example.com
```

## Upgrading from an older version

Versions prior to this one stored SFTP/local credentials directly in each job's
YAML (`sftp:`/`local:` blocks), or referenced a file transport via a `file_transport:
{id: ..., name: ...}` block. On upgrade, the plugin automatically creates an
equivalent entry under Koha's Administration > File transports for every `sftp:`/
`local:` job (and normalizes an existing `file_transport:` block onto the same
`file_transport_id` key), rewrites the job to reference it via `file_transport_id`,
and removes the old block - no manual action is required. The new transport is named
`PatronsImporterAdvanced: <job name>` so it's easy to find afterwards if you want
to consolidate several jobs onto one shared transport.

Caveats carried over from the `file_transport:` block this replaces:
* Key file authentication requires Koha 26.05 or later.
* On Koha 25.11, a `local` transport ignores a job's `path` override when the transport itself has its own download directory configured.

The transformers are stored within the `config` block of the Koha configuration file:
```xml
 <patrons_importer_advanced>
    <transformers>
        <dob>
          <![CDATA[
            sub {
              my ( $input_hash, $output_hash, $stash ) = @_;
              my ( $month, $day, $year ) = split( '/', $input_hash->{"Date of Birth"} );
              $output_hash->{dateofbirth} = "$year-$month-$day";
            };
          ]]>
        </dob>
        <phone>
          <![CDATA[
            sub {
              my ( $input_hash, $output_hash, $stash, $job ) = @_;
              my $phone = $input_hash->{"Cell Phone"} || $input_hash->{"Phone"};
              $phone =~ s/\D//g;
              $output_hash->{phone} = $phone;
            };
          ]]>
        </phone>
        <pin>
          <![CDATA[
            sub {
              my ( $input_hash, $output_hash, $stash, $job ) = @_;
              require Koha::Patrons;
              my $count = Koha::Patrons->count({ cardnumber => $output_hash->{cardnumber} });
              if ( !$count || $job->{force_generate_pin} ) {
               my $pin = 1000 + int(rand(8999));
               $output_hash->{patron_attributes} = "PIN:$pin";
              }
            };
          ]]>
        </pin>
    </transformers>
 </patrons_importer_advanced>
 ```

## Scheduling

This plugin runs whenever Koha's `misc/cronjobs/plugins_nightly.pl` cron script fires
for it. By default sites schedule that script once nightly, but nothing about it is
actually limited to once a day - you can add several crontab lines to check a source
more often, e.g. every 4 hours:

```
0 6,10,14,18 * * * plugins_nightly.pl -c -m name="Advanced Patrons Importer"
```

Running more often than the source file actually changes is safe and cheap: each job
records a content hash of its last-imported file, and a run whose downloaded file is
byte-for-byte identical to last time is skipped rather than re-imported. `run_on_dow`
still applies on top of this for day-of-week gating.

## Raw config ( copy and paste as a starter template )
```yaml
---
- name: EXAMPLE 
  disable: 0
  run_on_dow: 1,2,3,4,5 
  debug: 0
  verbose: 3
  post_import_transformer: my_post_import_transformer
  file_transport:
    id: 1
    name: My SFTP server
    directory: /my/dir
    filename: myfile.txt
  sftp:
    host: sftp.library.org
    port: 22
    username: admin
    password: secret
    directory: /my/dir 
    filename: myfile.txt
  local:
    directory: /kohadevbox/koha
    filename: ERU_student_data.txt
  file:
    header: Last Name|First Name|Middle Name|Date of Birth|Level|Email|Phone|Address 1|Address 2|City|State|Zip|Enrollment Status
  parameters:
    matchpoint: cardnumber
    preserve_extended_attributes: 1
    defaults:
      dateexpiry: 2099-01-01
      privacy: 1
    preserve_fields:
      - dateenrolled
      - password_expiration_date
      - fax
    overwrite_cardnumber: 1
    overwrite_passwords: 0
    update_dateexpiry: 1
    update_dateexpiry_from_today: 1
    update_dateexpiry_from_existing: 0
    send_welcome: 0
    dry_run: 0
  csv_options:
    sep_char: "\t"
  delete_incoming:
     - field: "sort1"
       value: "1"
       comparison: "equals"
     - field: "sort2"
       value: "1"
       comparison: "not_equals"
  columns:
    - output: branchcode
      static: ERU
    - output: surname 
      input: "Last Name"
      prefix: 1234
      padding: "0"
      length: 14       
    - name: Phone Number
      transformer: myTransformer
    - output: categorycode
      mapping:
        source: studentgrade
        map:
          "1": GRADESCHOOL
          "7": MIDDLESCHOOL
          "12": HIGHSCHOOL
          "K": GRADESCHOOL
  skip_incoming:
    "Some Column":
      - "9"
      - "71"
      - "106"
  send_email:
    subject: Your library's import results
    from: me@example.com
    to: you@example.com
    cc: him@example.com
    bcc: her@example.com
    reply_to: them@example.com
```

The transformers are stored within the `config` block of the Koha configuration file:
```xml
 <patrons_importer_advanced>
    <transformers>
        <dob>
          <![CDATA[
            sub {
              my ( $input_hash, $output_hash, $stash ) = @_;
              my ( $month, $day, $year ) = split( '/', $input_hash->{"Date of Birth"} );
              $output_hash->{dateofbirth} = "$year-$month-$day";
            };
          ]]>
        </dob>
        <phone>
          <![CDATA[
            sub {
              my ( $input_hash, $output_hash, $stash, $job ) = @_;
              my $phone = $input_hash->{"Cell Phone"} || $input_hash->{"Phone"};
              $phone =~ s/\D//g;
              $output_hash->{phone} = $phone;
            };
          ]]>
        </phone>
        <pin>
          <![CDATA[
            sub {
              my ( $input_hash, $output_hash, $stash, $job ) = @_;
              require Koha::Patrons;
              my $count = Koha::Patrons->count({ cardnumber => $output_hash->{cardnumber} });
              if ( !$count || $job->{force_generate_pin} ) {
               my $pin = 1000 + int(rand(8999));
               $output_hash->{patron_attributes} = "PIN:$pin";
              }
            };
          ]]>
        </pin>
    </transformers>
 </patrons_importer_advanced>
 ```
The Perl code is wrapped in CDATA sections to avoid the need to encode the Perl code as to not break the XML encoding.

# Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-patrons-importer-advanced/releases) you can download the latest release in `kpz` format.

# Installation

This plugin requires no special installation procedures.
