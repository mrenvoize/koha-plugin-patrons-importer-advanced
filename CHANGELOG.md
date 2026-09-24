# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Changed
- SFTP/local job configuration now references a Koha core File Transport (`file_transport_id`) instead of storing its own host/username/password. Existing configurations are migrated automatically on upgrade.
- The plugin's "Test connection" button now tests via the referenced File Transport.
### Added
- Jobs are now safe to schedule more than once a day: a job whose source file is unchanged since its last successful run is skipped instead of reprocessed, based on a content hash of the downloaded file.
- Overlapping runs of the same job are now prevented with a per-job database lock: a cron tick that finds a job still running from a previous tick skips it (with a log message) instead of double-importing.
- A job with a missing or unknown `file_transport_id` is now always reported in cron output and in the "Test connection" results instead of being skipped silently.
### Fixed
- The automatic upgrade migration is now atomic: if any job's transport cannot be created, no transport rows are left behind and the stored configuration is left untouched.
- A legacy `local` job whose `directory` contains Template Toolkit markup now migrates that directory to the job's `path` key (which is still rendered on every run) instead of storing it unrendered on the transport.
- Temporary download directories are now cleaned up instead of accumulating downloaded patron files under the system temp directory.

## [0.0.1] - 2022-12-02
### Added
- Initial commit!
