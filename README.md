# Appcircle Cache Pull

Downloads cache from Appcircle, extracts files and folders to source locations.

Required Input Variables

- `AC_CACHE_LABEL`: User defined cache label to identify one cache from others. Both cache push and pull steps should have the same value to match.
- `AC_TOKEN_ID`: System generated token used for getting signed url. Zipped cache file is uploaded to signed url.
- `ASPNETCORE_CALLBACK_URL`: System generated callback url for signed url web service. It's different for various environments.

Optional Input Variables

- `AC_REPOSITORY_DIR`: Cloned git repository path. Included and excluded paths are defined relative to cloned repository, except `~` prefixed paths.
