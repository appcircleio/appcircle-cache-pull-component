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
  run_command(command)
end

def abort_with0(message)
  puts "@@[error] #{message}"
  exit 0
end

ac_repository_path = get_env_variable('AC_REPOSITORY_DIR')
ac_cache_label = get_env_variable('AC_CACHE_LABEL') || abort_with0('Cache label path must be defined.')

ac_token_id = get_env_variable('AC_TOKEN_ID') || abort_with0('AC_TOKEN_ID env variable must be set when build started.')
ac_callback_url = get_env_variable('ASPNETCORE_CALLBACK_URL') ||
                  abort_with0('ASPNETCORE_CALLBACK_URL env variable must be set when build started.')

signed_url_api = "#{ac_callback_url}?action=getCacheUrls"

# check dependencies
run_command('unzip -v |head -1')
run_command('curl --version |head -1')

cache = "ac_cache/#{ac_cache_label}"
zipped = "ac_cache/#{ac_cache_label.gsub('/', '_')}.zip"

puts 'Inputs:'
puts ac_cache_label
puts ac_repository_path
puts '------'

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
    puts signed['getUrl']

    ENV['AC_CACHE_GET_URL'] = signed['getUrl']
    run_command("curl -X GET -H \"Content-Type: application/zip\" -o #{zipped} $AC_CACHE_GET_URL")
  end
end

exit 0 unless File.size?(zipped)
exit 0 if system("head -1 #{zipped} |grep -i -q NoSuchKey && rm -f #{zipped}")

md5sum = Digest::MD5.file(zipped).hexdigest
puts "MD5: #{md5sum}"
File.open("#{zipped}.md5", 'a') do |f|
  f.puts md5sum.to_s
end
run_command_with_log("unzip -qq #{zipped}")

Dir.glob("#{cache}/*.zip", File::FNM_DOTMATCH).each do |zip_file|
  run_command_with_log("unzip -qq #{zip_file} -d /")
end

Dir.glob("#{cache}/repository/*.zip", File::FNM_DOTMATCH).each do |zip_file|
  if ac_repository_path
    run_command_with_log("unzip -qq -u #{zip_file} -d #{ac_repository_path}")
  else
    puts "Warning: #{zip_file} is skipped. It can be used only after Git Clone workflow step."
  end
end
