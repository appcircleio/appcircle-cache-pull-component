# Appcircle Cache Pull

Downloads cache from Appcircle, extracts files and folders to source locations.

Required Input Variables

- `AC_CACHE_LABEL`: User defined cache label to identify one cache from others. Both cache push and pull steps should have the same value to match.
- `AC_TOKEN_ID`: System generated token used for getting signed url. Zipped cache file is uploaded to signed url.
- `AC_CALLBACK_URL`: System generated callback url for signed url web service. Its value is different for various environments.

Optional Input Variables

- `AC_REPOSITORY_DIR`: Cloned git repository path. Included and excluded paths are defined relative to cloned repository, except `~` prefixed paths.

## Running tests

Requires the [RSpec](https://rspec.info) gem and the Ruby standard library (Coverage, Open3, Digest). No Gemfile or Bundler needed.

```bash
gem install rspec   # once
ruby test/test_main.rb
```

The suite covers every function in `main.rb` in-process and runs the full script in a subprocess with the `unzip`/`curl` toolchain and the signed-URL HTTP call stubbed, so no real command is executed and no network is used. A pass/fail summary and a coverage report are printed at the end of each run.
