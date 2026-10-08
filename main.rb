require 'English'
require 'net/http'
require 'json'
require 'digest'
require 'open3'

def get_env_variable(key)
  return nil if ENV[key].nil? || ENV[key].strip.empty?

  ENV[key].strip
end

def run_command(command)
  unless system(command)
    puts "@@[error] Unexpected exit with code #{$CHILD_STATUS.exitstatus}. Check logs for details."
    exit 0
  end
end

def run_command_with_log(command)
  puts "@@[command] #{command}"
  s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  run_command(command)
  e = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  puts "took #{(e - s).round(3)}s"
end

def abort_with0(message)
  puts "@@[error] #{message}"
  exit 0
end

ac_repository_path = get_env_variable('AC_REPOSITORY_DIR')
ac_cache_label = get_env_variable('AC_CACHE_LABEL') || abort_with0('Cache label path must be defined.')
ac_cache_label = ac_cache_label.gsub(%r{[^A-Za-z0-9_/-]}, '_')

ac_token_id = get_env_variable('AC_TOKEN_ID') || abort_with0('AC_TOKEN_ID env variable must be set when build started.')
ac_callback_url = get_env_variable('AC_CALLBACK_URL') ||
                  abort_with0('AC_CALLBACK_URL env variable must be set when build started.')

signed_url_api = "#{ac_callback_url}?action=getCacheUrls"

def command_exists?(name)
  system("command -v #{name} > /dev/null 2>&1")
end

# check dependencies
run_command('curl --version |head -1')

cache = "ac_cache/#{ac_cache_label}"
zipped = "ac_cache/#{ac_cache_label.gsub('/', '_')}.zip"

puts '--- Inputs:'
puts ac_cache_label
puts ac_repository_path
puts '-----------'

env_dirs = Hash.new('')
ENV.each_pair do |k, v|
  next unless k.start_with?('AC_')
  next if v.include?('//') || v.include?(':')

  env_dirs[k] = v if File.directory?(v) || %r{^(.+)/([^/]+)$} =~ v
end

system("rm -rf #{cache}")
system("mkdir -p #{cache}")

unless ac_token_id.empty?
  puts ''

  ws_signed_url = "#{signed_url_api}&cacheKey=#{ac_cache_label.gsub('/', '_')}&tokenId=#{ac_token_id}"
  puts ws_signed_url

  uri = URI(ws_signed_url)
  response = Net::HTTP.get(uri)
  unless response.empty?
    puts 'Downloading cache...'

    signed = JSON.parse(response)
    ENV['AC_CACHE_GET_URL'] = signed['getUrl']
    puts ENV['AC_CACHE_GET_URL']
    if get_env_variable('AC_CACHE_PROVIDER').eql?('FILESYSTEM')
      run_command_with_log("curl -X GET --fail -o #{zipped} '#{ENV['AC_CACHE_GET_URL']}'")
    else
      run_command_with_log("curl -X GET -H \"Content-Type: application/zip\" --fail -o #{zipped} $AC_CACHE_GET_URL")
    end
  end
end

exit 0 unless File.size?(zipped)

# Legacy MD5 of the bundle, used by older cache push versions.
md5sum = Digest::MD5.file(zipped).hexdigest
puts "MD5: #{md5sum}"
File.open("#{zipped}.md5", 'a') do |f|
  f.puts md5sum.to_s
end

# Cache push writes either a zip bundle (legacy) or a tar bundle (zstd). The remote object keeps the
# ".zip" name in both cases, so the format is detected from the file header.
def zip_file?(file)
  File.open(file, 'rb') { |f| f.read(2) } == 'PK'
end

if zip_file?(zipped)
  run_command('unzip -v |head -1')
  run_command_with_log("unzip -qq -o #{zipped}")
else
  run_command('tar --version |head -1')
  run_command_with_log("tar -xf #{zipped}")
end

# Digest of the archives inside the cache folder. Cache push computes the same digest before it
# builds the bundle and skips the upload when nothing changed.
def cache_digest(cache_dir)
  digest = Digest::MD5.new
  Dir.glob("#{cache_dir}/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) }.sort.each do |f|
    digest << "#{f.delete_prefix("#{cache_dir}/")}\0#{Digest::MD5.file(f).hexdigest}\n"
  end
  digest.hexdigest
end

File.write("#{zipped}.digest", "#{cache_digest(cache)}\n")

def extract_tar_zst(archive_file, base_path)
  zstd = ['zstd', '-d', '-c', '-q', archive_file]
  tar = ['tar', '-xf', '-', '-C', "#{base_path}/"]
  puts "@@[command] #{zstd.join(' ')} | #{tar.join(' ')}"
  s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  zstd_status, tar_status = Open3.pipeline(zstd, tar)
  e = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  unless zstd_status.success? && tar_status.success?
    abort_with0("Unexpected exit (zstd: #{zstd_status.exitstatus}, tar: #{tar_status.exitstatus}) " \
                "while extracting #{archive_file}.")
  end
  puts "took #{(e - s).round(3)}s"
end

zstd_available = command_exists?('zstd')

Dir.glob(["#{cache}/**/*.zip", "#{cache}/**/*.tar.zst"], File::FNM_DOTMATCH).each do |archive_file|
  puts archive_file

  last_slash = archive_file.rindex('/')
  base_path = archive_file[cache.length..last_slash - 1]
  base_path = env_dirs[base_path[1..-1]] if env_dirs.key?(base_path[1..-1])

  puts base_path
  system("mkdir -p #{base_path}")
  if archive_file.end_with?('.tar.zst')
    unless zstd_available
      puts "Warning: zstd is not available on this runner. #{archive_file} is skipped."
      next
    end
    extract_tar_zst(archive_file, base_path)
  else
    run_command_with_log("unzip -qq -u -o #{archive_file} -d #{base_path}/")
  end
end
