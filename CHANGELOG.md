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

## [0.0.1] - 2022-12-02
### Added
- Initial commit!
