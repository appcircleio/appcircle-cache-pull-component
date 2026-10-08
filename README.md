# Appcircle Cache Pull

Downloads cache from Appcircle, extracts files and folders to source locations.

Required Input Variables

- `AC_CACHE_LABEL`: User defined cache label to identify one cache from others. Both cache push and pull steps should have the same value to match.
- `AC_TOKEN_ID`: System generated token used for getting signed url. Zipped cache file is uploaded to signed url.
- `AC_CALLBACK_URL`: System generated callback url for signed url web service. Its value is different for various environments.

Optional Input Variables

- `AC_REPOSITORY_DIR`: Cloned git repository path. Included and excluded paths are defined relative to cloned repository, except `~` prefixed paths.

## Cache Formats

Cache pull supports both formats written by Cache Push: the legacy zip bundle and the tar bundle with `.tar.zst` archives. The format is detected from the downloaded file header. Extracting `.tar.zst` archives requires `zstd` on the runner; without it those archives are skipped with a warning (cache miss, the build continues).
