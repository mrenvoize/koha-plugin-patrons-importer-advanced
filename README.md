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
  file_transport: # Use a file transport defined in Koha under Administration > File transports ( Koha 25.11 or later )
    id: 1                  # The file transport id, visible in the URL when editing the transport
    name: My SFTP server   # Alternative to id, must match exactly one file transport
    directory: /my/dir     # Optional, overrides the transport's download directory. Can be template toolkit markup
    filename: myfile.txt   # Can be template toolkit markup
  sftp:         # Connection settings stored in this configuration, ignored if file_transport or local is set
    host: sftp.library.org
    port: 22 # Optional, defaults to 22
    username: admin
    password: secret
    directory: /my/dir # Can be template toolkit markup, e.g. `"[% USE date %]CCC_STUDENTS_[% date.format(date.now, '%Y%m%d') %].csv"`
    filename: myfile.txt # Can be template toolkit markup
  local:        # If a local file is set, file_transport and sftp settings will be ignored
    directory: /kohadevbox/koha # Can be template toolkit markup
    filename: ERU_student_data.txt # Can be template toolkit markup
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

## File transports

On Koha 25.11 or later the connection can be a Koha file transport ( Administration > File transports ) instead of an `sftp` block. File transports support SFTP with a password or a key file, and FTP, and keep the credentials out of the plugin configuration. Reference the transport by its `id` or its `name`, and set the `filename` to download. The transport's download directory is used unless the job sets its own `directory`.

Caveats:
* Key file authentication requires Koha 26.05 or later.
* On Koha 25.11, a `local` transport ignores the job's `directory` when the transport has its own download directory.

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
