# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'
require 'stringio'
require 'rbconfig'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m"   # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth.positive?
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f.positive?
    parts << "\e[33m#{s} pending\e[0m" if s.positive?

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Capture everything written to $stdout while the block runs.
# SystemExit raised inside the block propagates after $stdout is restored.
def capture_stdout
  old = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  captured = $stdout.string if $stdout.is_a?(StringIO)
  $stdout = old
  @last_stdout = captured
end

# Set $CHILD_STATUS ($?) to a non-zero exit code without touching the shell or
# any external toolchain: only the already-running Ruby interpreter is spawned.
def set_child_status(code)
  Process.wait(Process.spawn(RbConfig.ruby, '-e', "exit #{code}"))
end

# Stub Kernel#system on the example so that no command is ever executed.
# Returns the array that collects the composed command strings.
def stub_system(success: true, exit_code: 0)
  captured = []
  allow(self).to receive(:system) do |cmd|
    captured << cmd
    set_child_status(exit_code) unless success
    success
  end
  captured
end

# Kernel#system(nil) raises TypeError before spawning anything; make the stub
# reproduce that so the nil-command tests never reach a shell either.
def stub_system_passthrough_nil
  allow(self).to receive(:system) do |cmd|
    raise TypeError, 'no implicit conversion of nil into String' if cmd.nil?

    true
  end
end

# Where the subprocess runs drop their Coverage dumps (merged in the report).
SUBPROCESS_COVERAGE_DIR = Dir.mktmpdir('cache_pull_cov')
at_exit { FileUtils.rm_rf(SUBPROCESS_COVERAGE_DIR) }

# Every ENV key main.rb reads, plus the test-only control knobs. Passing nil to
# Open3.capture3 unsets the key in the child, isolating the subprocess tests
# from the ambient environment.
MAIN_ENV_KEYS = %w[
  AC_REPOSITORY_DIR
  AC_CACHE_LABEL
  AC_TOKEN_ID
  AC_CALLBACK_URL
  AC_CACHE_PROVIDER
  AC_CACHE_GET_URL
  _TEST_HTTP_BODY
  _TEST_COVERAGE_DIR
].freeze

# Preloaded into the child via RUBYOPT=-r<file>. It replaces Kernel#system and
# Net::HTTP.get so the subprocess never runs unzip/curl/rm/mkdir and never opens
# a network connection. Every stubbed call is echoed to stdout so the tests can
# assert the composed command strings.
MAIN_STUB_SOURCE = <<~'RUBY_SRC'
  # Coverage for the guarded main block: start before main.rb loads and dump
  # the per-line counts on exit so the parent can merge them into its report.
  if ENV['_TEST_COVERAGE_DIR'] && !ENV['_TEST_COVERAGE_DIR'].empty?
    require 'coverage'
    require 'json'
    Coverage.start
    at_exit do
      result = Coverage.result
      path   = result.keys.find { |k| k.end_with?('/main.rb') }
      if path
        file = File.join(ENV['_TEST_COVERAGE_DIR'], "cov-#{Process.pid}-#{rand(1_000_000)}.json")
        File.write(file, JSON.generate({ 'path' => path, 'lines' => result[path] }))
      end
    end
  end

  require 'net/http'

  module Kernel
    def system(*args)
      $stdout.puts "[stub-system] #{args.join(' ')}"
      true
    end
  end

  Net::HTTP.singleton_class.send(:define_method, :get) do |uri, *_rest|
    $stdout.puts "[stub-http] GET #{uri}"
    ENV.fetch('_TEST_HTTP_BODY', '')
  end
RUBY_SRC

# Run main.rb in a subprocess with a controlled ENV and the stub preloaded.
# Returns [stdout, stderr, status]. `chdir` defaults to a throw-away tmpdir so
# the script never writes outside of it; pass a caller-owned dir to inspect the
# files main.rb left behind.
def run_main(env = {}, chdir: nil)
  Dir.mktmpdir('cache_pull_main') do |tmp|
    stub_path = File.join(tmp, 'main_stub.rb')
    File.write(stub_path, MAIN_STUB_SOURCE)

    # Unset every AC_* key the parent happens to carry as well: main.rb scans
    # the whole environment for AC_-prefixed directory hints.
    ambient_ac = ENV.keys.select { |k| k.start_with?('AC_') }
    clean_env  = (MAIN_ENV_KEYS + ambient_ac).uniq.to_h { |k| [k, nil] }.merge(env)
    clean_env['RUBYOPT'] = ["-r#{stub_path}", ENV['RUBYOPT']].compact.join(' ')
    clean_env['_TEST_COVERAGE_DIR'] = SUBPROCESS_COVERAGE_DIR

    Open3.capture3(clean_env, "ruby #{MAIN_RB}", chdir: chdir || tmp)
  end
end

# A complete, valid ENV for main.rb. Callers merge overrides on top.
def valid_main_env(repo_dir, overrides = {})
  {
    'AC_CACHE_LABEL'    => 'main/cache',
    'AC_TOKEN_ID'       => 'token-123',
    'AC_CALLBACK_URL'   => 'https://api.example.test/callback',
    'AC_REPOSITORY_DIR' => repo_dir
  }.merge(overrides)
end

# The signed-URL web service response main.rb parses for the download URL.
def signed_response_body(get_url: 'https://download.example.test/cache.zip')
  body = {}
  body['getUrl'] = get_url unless get_url == :omit
  body.to_json
end

ZIP_CONTENT = 'fake zip content'
ZIP_MD5     = Digest::MD5.hexdigest(ZIP_CONTENT)

# Build the workspace main.rb expects to find after its (stubbed) curl download
# has "run": the downloaded cache zip, plus any nested zips inside the cache
# folder for the extraction loop to walk.
def prepare_cache_workspace(tmp, label: 'main/cache', zip_content: ZIP_CONTENT, nested: {})
  repo = File.join(tmp, 'repo')
  FileUtils.mkdir_p(repo)
  FileUtils.mkdir_p(File.join(tmp, 'ac_cache'))
  File.write(File.join(tmp, 'ac_cache', "#{label.gsub('/', '_')}.zip"), zip_content) if zip_content
  nested.each do |rel, content|
    path = File.join(tmp, 'ac_cache', label, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
  repo
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env_variable' do
  around do |example|
    old = ENV['_TEST_VAR']
    example.run
    old.nil? ? ENV.delete('_TEST_VAR') : ENV['_TEST_VAR'] = old
  end

  it 'returns the value when the key is set' do
    ENV['_TEST_VAR'] = 'hello'
    expect(get_env_variable('_TEST_VAR')).to eq('hello')
  end

  it 'strips surrounding whitespace' do
    ENV['_TEST_VAR'] = "  hello \n"
    expect(get_env_variable('_TEST_VAR')).to eq('hello')
  end

  it 'returns nil when the key is missing' do
    ENV.delete('_TEST_VAR')
    expect(get_env_variable('_TEST_VAR')).to be_nil
  end

  it 'returns nil when the value is an empty string' do
    ENV['_TEST_VAR'] = ''
    expect(get_env_variable('_TEST_VAR')).to be_nil
  end

  it 'returns nil when the value is only whitespace' do
    ENV['_TEST_VAR'] = "   \t"
    expect(get_env_variable('_TEST_VAR')).to be_nil
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command' do
  it 'passes the command string to system untouched and does not exit on success' do
    captured = stub_system
    expect { run_command('unzip -v |head -1') }.not_to raise_error
    expect(captured).to eq(['unzip -v |head -1'])
  end

  it 'prints nothing on success' do
    stub_system
    out = capture_stdout { run_command('curl --version |head -1') }
    expect(out).to eq('')
  end

  it 'exits with status 0 and reports the child exit code when the command fails' do
    stub_system(success: false, exit_code: 3)
    expect do
      capture_stdout { run_command('unzip -qq -o missing.zip') }
    end.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to include('@@[error] Unexpected exit with code 3')
    expect(@last_stdout).to include('Check logs for details.')
  end

  it 'raises TypeError for a nil command (system(nil))' do
    stub_system_passthrough_nil
    expect { run_command(nil) }.to raise_error(TypeError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command_with_log' do
  it 'logs the command, runs it, and prints the elapsed time' do
    captured = stub_system
    out = capture_stdout { run_command_with_log('unzip -qq -o ac_cache/main_cache.zip') }
    expect(captured).to eq(['unzip -qq -o ac_cache/main_cache.zip'])
    expect(out).to include('@@[command] unzip -qq -o ac_cache/main_cache.zip')
    expect(out).to match(/took \d+\.\d+s/)
  end

  it 'exits with status 0 when the underlying command fails' do
    stub_system(success: false, exit_code: 1)
    expect do
      capture_stdout { run_command_with_log('curl -X GET --fail -o cache.zip https://example.test') }
    end.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to include('@@[command] curl -X GET --fail -o cache.zip https://example.test')
    expect(@last_stdout).to include('@@[error] Unexpected exit with code 1')
    expect(@last_stdout).not_to match(/took/)
  end

  it 'raises TypeError for a nil command after logging it' do
    stub_system_passthrough_nil
    expect { capture_stdout { run_command_with_log(nil) } }.to raise_error(TypeError)
    expect(@last_stdout).to include('@@[command] ')
  end

  it 'logs an empty command string without raising' do
    captured = stub_system
    out = capture_stdout { run_command_with_log('') }
    expect(captured).to eq([''])
    expect(out).to include('@@[command] ')
    expect(out).to match(/took \d+\.\d+s/)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#abort_with0' do
  it 'prints the message with the @@[error] prefix and exits with status 0' do
    expect do
      capture_stdout { abort_with0('Cache label path must be defined.') }
    end.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to eq("@@[error] Cache label path must be defined.\n")
  end

  it 'still exits with status 0 for an empty message' do
    expect { capture_stdout { abort_with0('') } }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to eq("@@[error] \n")
  end

  it 'still exits with status 0 for a nil message' do
    expect { capture_stdout { abort_with0(nil) } }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to eq("@@[error] \n")
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation (subprocess)' do
  # main.rb reports configuration errors through abort_with0, which prints
  # "@@[error] ..." to stdout and exits 0 on purpose so a cache problem never
  # fails the whole build. The assertions therefore check for the error line
  # and that the script stopped before doing any work.
  shared_examples 'aborts before doing any work' do |expected_message, env|
    it "prints '@@[error] #{expected_message}' and stops" do
      out, _err, status = run_main(env)
      expect(status.exitstatus).to eq(0)
      expect(out).to include("@@[error] #{expected_message}")
      expect(out).not_to include('--- Inputs:')
      expect(out).not_to include('[stub-system]')
      expect(out).not_to include('[stub-http]')
    end
  end

  let(:tmpdir) { File.realpath(Dir.mktmpdir('env_validation')) }
  after { FileUtils.rm_rf(tmpdir) }

  context 'AC_CACHE_LABEL' do
    context 'when missing' do
      include_examples 'aborts before doing any work', 'Cache label path must be defined.', {}
    end

    context 'when empty' do
      include_examples 'aborts before doing any work', 'Cache label path must be defined.',
                       { 'AC_CACHE_LABEL' => '' }
    end

    context 'when only whitespace' do
      include_examples 'aborts before doing any work', 'Cache label path must be defined.',
                       { 'AC_CACHE_LABEL' => '   ' }
    end
  end

  context 'AC_TOKEN_ID' do
    context 'when missing' do
      include_examples 'aborts before doing any work', 'AC_TOKEN_ID env variable must be set when build started.',
                       { 'AC_CACHE_LABEL' => 'main/cache' }
    end

    context 'when empty' do
      include_examples 'aborts before doing any work', 'AC_TOKEN_ID env variable must be set when build started.',
                       { 'AC_CACHE_LABEL' => 'main/cache', 'AC_TOKEN_ID' => '' }
    end
  end

  context 'AC_CALLBACK_URL' do
    context 'when missing' do
      include_examples 'aborts before doing any work', 'AC_CALLBACK_URL env variable must be set when build started.',
                       { 'AC_CACHE_LABEL' => 'main/cache', 'AC_TOKEN_ID' => 'token-123' }
    end

    context 'when empty' do
      include_examples 'aborts before doing any work', 'AC_CALLBACK_URL env variable must be set when build started.',
                       { 'AC_CACHE_LABEL' => 'main/cache', 'AC_TOKEN_ID' => 'token-123',
                         'AC_CALLBACK_URL' => '' }
    end
  end

  context 'AC_REPOSITORY_DIR (optional)' do
    it 'passes validation and runs the dependency checks when missing' do
      out, _err, status = run_main(valid_main_env(nil).compact, chdir: tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(out).to include('--- Inputs:')
      expect(out).to include('[stub-system] unzip -v |head -1')
      expect(out).to include('[stub-system] curl --version |head -1')
    end

    it 'echoes the repository path in the inputs block when set' do
      out, _err, status = run_main(valid_main_env(tmpdir), chdir: tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(out).to include("--- Inputs:\nmain/cache\n#{tmpdir}\n-----------")
    end
  end

  context 'AC_CACHE_LABEL sanitization' do
    it 'replaces characters outside [A-Za-z0-9_/-] with an underscore' do
      out, _err, status = run_main(
        valid_main_env(tmpdir,
                       'AC_CACHE_LABEL'   => 'feat/my cache!',
                       'AC_CACHE_PROVIDER' => 'FILESYSTEM',
                       '_TEST_HTTP_BODY'  => signed_response_body),
        chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('feat/my_cache_')
      expect(out).not_to include('feat/my cache!')
      # the flattened label is what names the downloaded zip and the cache key
      expect(out).to include('cacheKey=feat_my_cache_')
      expect(out).to include('-o ac_cache/feat_my_cache_.zip')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'signed URL request (subprocess)' do
  let(:tmpdir) { File.realpath(Dir.mktmpdir('signed_url')) }
  after { FileUtils.rm_rf(tmpdir) }

  it 'composes the getCacheUrls query from the callback URL, label and token' do
    out, _err, status = run_main(valid_main_env(tmpdir), chdir: tmpdir)
    expect(status.exitstatus).to eq(0)
    expect(out).to include(
      'https://api.example.test/callback?action=getCacheUrls&cacheKey=main_cache&tokenId=token-123'
    )
    expect(out).to include(
      '[stub-http] GET https://api.example.test/callback?action=getCacheUrls&cacheKey=main_cache&tokenId=token-123'
    )
  end

  it 'skips the download entirely when the response body is empty' do
    out, _err, status = run_main(valid_main_env(tmpdir, '_TEST_HTTP_BODY' => ''), chdir: tmpdir)
    expect(status.exitstatus).to eq(0)
    expect(out).to include('[stub-http] GET')
    expect(out).not_to include('Downloading cache...')
    expect(out).not_to include('curl -X GET')
  end

  it 'announces the download when the response body is present' do
    out, _err, status = run_main(
      valid_main_env(tmpdir, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
    )
    expect(status.exitstatus).to eq(0)
    expect(out).to include('Downloading cache...')
  end

  it 'fails with a JSON parse error (non-zero exit) when the response is not valid JSON' do
    out, err, status = run_main(valid_main_env(tmpdir, '_TEST_HTTP_BODY' => 'not json at all'), chdir: tmpdir)
    expect(status.exitstatus).not_to eq(0)
    expect(err).to match(/JSON|unexpected/i)
    expect(out).to include('Downloading cache...')
    expect(out).not_to include('curl -X GET')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'AC_CACHE_GET_URL (set by main.rb from the signed URL response)' do
  let(:tmpdir) { File.realpath(Dir.mktmpdir('get_url')) }
  after { FileUtils.rm_rf(tmpdir) }

  # The FILESYSTEM provider interpolates ENV['AC_CACHE_GET_URL'] straight into
  # the curl command, which makes the resolved value observable from outside.
  context 'with the FILESYSTEM provider' do
    let(:env) { valid_main_env(tmpdir, 'AC_CACHE_PROVIDER' => 'FILESYSTEM') }

    it 'is set from uploadInformation-free getUrl and used as the curl target' do
      out, _err, status = run_main(
        env.merge('_TEST_HTTP_BODY' => signed_response_body(get_url: 'https://dl.example.test/c.zip')),
        chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('https://dl.example.test/c.zip')
      expect(out).to include(
        "[stub-system] curl -X GET --fail -o ac_cache/main_cache.zip 'https://dl.example.test/c.zip'"
      )
    end

    it 'ends up blank (empty quoted curl target) when getUrl is absent from the response' do
      out, _err, status = run_main(
        env.merge('_TEST_HTTP_BODY' => signed_response_body(get_url: :omit)), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include("[stub-system] curl -X GET --fail -o ac_cache/main_cache.zip ''")
    end

    it 'ends up blank (empty quoted curl target) when getUrl is an empty string' do
      out, _err, status = run_main(
        env.merge('_TEST_HTTP_BODY' => signed_response_body(get_url: '')), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include("[stub-system] curl -X GET --fail -o ac_cache/main_cache.zip ''")
    end

    it 'overwrites a stale pre-set value with the one from the response' do
      out, _err, status = run_main(
        env.merge('AC_CACHE_GET_URL' => 'https://stale.example.test/old',
                  '_TEST_HTTP_BODY'  => signed_response_body(get_url: 'https://fresh.example.test/new')),
        chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include("--fail -o ac_cache/main_cache.zip 'https://fresh.example.test/new'")
      expect(out).not_to include('stale.example.test')
    end
  end

  context 'with any other provider' do
    it 'passes AC_CACHE_GET_URL to curl as a shell variable with a zip Content-Type' do
      out, _err, status = run_main(
        valid_main_env(tmpdir, 'AC_CACHE_PROVIDER' => 'S3',
                               '_TEST_HTTP_BODY'   => signed_response_body),
        chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include(
        '[stub-system] curl -X GET -H "Content-Type: application/zip" --fail ' \
        '-o ac_cache/main_cache.zip $AC_CACHE_GET_URL'
      )
    end

    it 'takes the same branch when AC_CACHE_PROVIDER is unset (nil never reaches .eql? unsafely)' do
      out, _err, status = run_main(
        valid_main_env(tmpdir, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-H "Content-Type: application/zip"')
      expect(out).not_to include("--fail -o ac_cache/main_cache.zip 'https")
    end

    it 'takes the same branch when AC_CACHE_PROVIDER is empty' do
      out, _err, status = run_main(
        valid_main_env(tmpdir, 'AC_CACHE_PROVIDER' => '',
                               '_TEST_HTTP_BODY'   => signed_response_body),
        chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-H "Content-Type: application/zip"')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'cache download and extraction (subprocess)' do
  let(:tmpdir) { File.realpath(Dir.mktmpdir('extract')) }
  after { FileUtils.rm_rf(tmpdir) }

  context 'when the (stubbed) download left no usable archive' do
    it 'exits 0 without computing an MD5 or unzipping when the zip is absent' do
      out, _err, status = run_main(
        valid_main_env(tmpdir, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('MD5:')
      expect(out).not_to include('unzip -qq -o')
    end

    it 'exits 0 without computing an MD5 when the zip is zero bytes' do
      repo = prepare_cache_workspace(tmpdir, zip_content: '')
      out, _err, status = run_main(
        valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('MD5:')
      expect(out).not_to include('unzip -qq -o')
    end
  end

  context 'when the downloaded archive is present' do
    it 'prints the MD5 of the archive and unzips it in place' do
      repo = prepare_cache_workspace(tmpdir)
      out, _err, status = run_main(
        valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include("MD5: #{ZIP_MD5}")
      expect(out).to include('[stub-system] unzip -qq -o ac_cache/main_cache.zip')
    end

    it 'writes the digest to a .md5 sidecar next to the archive' do
      repo = prepare_cache_workspace(tmpdir)
      _out, _err, status = run_main(
        valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      sidecar = File.join(tmpdir, 'ac_cache', 'main_cache.zip.md5')
      expect(File.read(sidecar).strip).to eq(ZIP_MD5)
    end

    it 'appends to the .md5 sidecar rather than replacing it across runs' do
      repo = prepare_cache_workspace(tmpdir)
      env  = valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body)
      2.times { run_main(env, chdir: tmpdir) }
      sidecar = File.join(tmpdir, 'ac_cache', 'main_cache.zip.md5')
      expect(File.read(sidecar).lines.map(&:strip)).to eq([ZIP_MD5, ZIP_MD5])
    end
  end

  context 'restoring nested archives to their source locations' do
    it 'maps a folder named after an AC_ directory variable back to that path' do
      repo = prepare_cache_workspace(tmpdir, nested: { 'AC_REPOSITORY_DIR/inner.zip' => 'inner' })
      out, _err, status = run_main(
        valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include("[stub-system] mkdir -p #{repo}")
      expect(out).to include(
        "[stub-system] unzip -qq -u -o ac_cache/main/cache/AC_REPOSITORY_DIR/inner.zip -d #{repo}/"
      )
    end

    it 'keeps the folder name as the target when it is not a known AC_ variable' do
      repo = prepare_cache_workspace(tmpdir, nested: { 'somedir/inner.zip' => 'inner' })
      out, _err, status = run_main(
        valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include(
        '[stub-system] unzip -qq -u -o ac_cache/main/cache/somedir/inner.zip -d /somedir/'
      )
    end

    it 'keeps a multi-segment folder path as the target' do
      repo = prepare_cache_workspace(tmpdir, nested: { 'deep/nested/inner.zip' => 'inner' })
      out, _err, status = run_main(
        valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include(
        '[stub-system] unzip -qq -u -o ac_cache/main/cache/deep/nested/inner.zip -d /deep/nested/'
      )
    end

    # Documents current behaviour: a zip sitting directly in the cache folder
    # has no folder segment to map, so the extraction target resolves to "/".
    it 'resolves an empty target for a zip sitting directly in the cache folder' do
      repo = prepare_cache_workspace(tmpdir, nested: { 'root.zip' => 'root' })
      out, _err, status = run_main(
        valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('[stub-system] unzip -qq -u -o ac_cache/main/cache/root.zip -d /')
    end

    it 'walks every nested archive found under the cache folder' do
      repo = prepare_cache_workspace(
        tmpdir, nested: { 'AC_REPOSITORY_DIR/a.zip' => 'a', 'somedir/b.zip' => 'b' }
      )
      out, _err, status = run_main(
        valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include("-o ac_cache/main/cache/AC_REPOSITORY_DIR/a.zip -d #{repo}/")
      expect(out).to include('-o ac_cache/main/cache/somedir/b.zip -d /somedir/')
    end

    it 'does nothing beyond the top-level unzip when no nested archive exists' do
      repo = prepare_cache_workspace(tmpdir)
      out, _err, status = run_main(
        valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('[stub-system] unzip -qq -o ac_cache/main_cache.zip')
      expect(out).not_to include('unzip -qq -u -o')
    end
  end

  context 'full happy path' do
    it 'runs dependency checks, downloads, verifies and restores in order' do
      repo = prepare_cache_workspace(tmpdir, nested: { 'AC_REPOSITORY_DIR/inner.zip' => 'inner' })
      out, err, status = run_main(
        valid_main_env(repo, 'AC_CACHE_PROVIDER' => 'FILESYSTEM',
                             '_TEST_HTTP_BODY'   => signed_response_body),
        chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0), "stdout:\n#{out}\nstderr:\n#{err}"

      order = [
        '[stub-system] unzip -v |head -1',
        '[stub-system] curl --version |head -1',
        '--- Inputs:',
        '[stub-http] GET https://api.example.test/callback?action=getCacheUrls',
        'Downloading cache...',
        "[stub-system] curl -X GET --fail -o ac_cache/main_cache.zip 'https://download.example.test/cache.zip'",
        "MD5: #{ZIP_MD5}",
        '[stub-system] unzip -qq -o ac_cache/main_cache.zip',
        "[stub-system] unzip -qq -u -o ac_cache/main/cache/AC_REPOSITORY_DIR/inner.zip -d #{repo}/"
      ]
      positions = order.map { |needle| out.index(needle) }
      expect(positions).to all(be_truthy)
      expect(positions).to eq(positions.sort)
    end

    it 'never executes the real unzip/curl toolchain and never opens a socket' do
      repo = prepare_cache_workspace(tmpdir)
      out, _err, _status = run_main(
        valid_main_env(repo, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir
      )
      # Every shell-out and the single HTTP call are accounted for by a stub line.
      expect(out.scan(/^\[stub-system\] /).size).to be >= 4
      expect(out.scan(/^\[stub-http\] /).size).to eq(1)
      # A real `unzip -v` would print its version banner; a real curl its own.
      expect(out).not_to match(/UnZip \d/)
      expect(out).not_to match(/^curl \d/)
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
# The guarded main block only runs in the `ruby main.rb` subprocesses, which
# in-process Coverage cannot see. Each child starts Coverage through the
# RUBYOPT-preloaded stub and dumps its counts; they are merged here.
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data  = result[main_path].dup
  dumps = Dir.glob(File.join(SUBPROCESS_COVERAGE_DIR, 'cov-*.json'))
  dumps.each do |file|
    child = JSON.parse(File.read(file))['lines']
    child.each_with_index do |count, i|
      next if count.nil? || data[i].nil?

      data[i] += count
    end
  end

  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i.positive? }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i.zero? }.map { |_, i| i + 1 }

  color = if pct == 100 then "\e[32;1m"
          elsif pct >= 80 then "\e[33m"
          else "\e[31m"
          end
  bar_filled = (pct / 5).round
  bar = "\e[32m#{'█' * bar_filled}\e[90m#{'░' * (20 - bar_filled)}\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  puts "  \e[90mmerged from this process + #{dumps.size} subprocess run(s)\e[0m"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color = true
    config.order = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
