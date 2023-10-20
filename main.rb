require 'English'
require 'net/http'
require 'json'
require 'digest'

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

ac_token_id = get_env_variable('AC_TOKEN_ID') || abort_with0('AC_TOKEN_ID env variable must be set when build started.')
ac_callback_url = get_env_variable('AC_CALLBACK_URL') ||
                  abort_with0('AC_CALLBACK_URL env variable must be set when build started.')

signed_url_api = "#{ac_callback_url}?action=getCacheUrls"

# check dependencies
run_command('unzip -v |head -1')
run_command('curl --version |head -1')

cache = "ac_cache/#{ac_cache_label}"
zipped = "ac_cache/#{ac_cache_label.gsub('/', '_')}.zip"

puts '--- Inputs:'
puts ac_cache_label
puts ac_repository_path
puts '-----------'

puts "test update-1"

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

md5sum = Digest::MD5.file(zipped).hexdigest
puts "MD5: #{md5sum}"
File.open("#{zipped}.md5", 'a') do |f|
  f.puts md5sum.to_s
end
run_command_with_log("unzip -qq -o #{zipped}")

Dir.glob("#{cache}/**/*.zip", File::FNM_DOTMATCH).each do |zip_file|
  puts zip_file

  last_slash = zip_file.rindex('/')
  base_path = zip_file[cache.length..last_slash - 1]
  base_path = env_dirs[base_path[1..-1]] if env_dirs.key?(base_path[1..-1])

  puts base_path
  system("mkdir -p #{base_path}")
  run_command_with_log("unzip -qq -u -o #{zip_file} -d #{base_path}/")
end
