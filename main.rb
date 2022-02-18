require 'English'
require 'net/http'
require 'json'

def get_env_variable(key)
  return nil if ENV[key].nil? || ENV[key].strip.empty?

  ENV[key].strip
end

def run_command(command)
  puts "@@[command] #{command}"
  exit $CHILD_STATUS.exitstatus unless system(command)
end

def run_command_silent(command)
  exit $CHILD_STATUS.exitstatus unless system(command)
end

def install_deps_if_not_exist(tool)
  run_command_silent("dpkg -s #{tool} > /dev/null 2>&1 || apt-get -y install #{tool} > /dev/null 2>&1")
end

ac_repository_path = get_env_variable('AC_REPOSITORY_DIR')
ac_cache_label = get_env_variable('AC_CACHE_LABEL') || abort('Cache label path must be defined.')
ac_token_id = get_env_variable('AC_TOKEN_ID') || abort('AC_TOKEN_ID env variable must be set when build started.')

# @todo: base url should be dynamic
signed_url_api = 'https://dev-api.appcircle.io/build/v1/callback?action=getCacheUrls'

install_deps_if_not_exist('curl')
install_deps_if_not_exist('unzip')

@cache = "ac_cache/#{ac_cache_label}"
zipped = "ac_cache/#{ac_cache_label.gsub('/', '_')}.zip"

puts 'Inputs:'
puts ac_cache_label
puts ac_repository_path
puts '------'

system("rm -rf #{@cache}")
system("mkdir -p #{@cache}")

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
    run_command_silent("curl -X GET -H \"Content-Type: application/zip\" -o #{zipped} $AC_CACHE_GET_URL")
  end
end

exit 0 unless File.size?(zipped)
exit 0 if system("head -1 #{zipped} |grep -i -q NoSuchKey && rm -f #{zipped}")

run_command("unzip -qq #{zipped}")

Dir.glob("#{@cache}/*.zip", File::FNM_DOTMATCH).each do |zip_file|
  run_command("unzip -qq #{zip_file} -d /")
end

Dir.glob("#{@cache}/repository/*.zip", File::FNM_DOTMATCH).each do |zip_file|
  if ac_repository_path
    run_command("unzip -qq -u #{zip_file} -d #{ac_repository_path}")
  else
    puts "Warning: #{zip_file} is ignored. It can be used only after Git Clone workflow step."
  end
end
