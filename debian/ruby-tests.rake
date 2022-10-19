require 'rspec/core/rake_task'

task :default do
  ruby = RbConfig::CONFIG['ruby_install_name']
  sh "./debian/start_memcached_and_run.sh #{ruby} -S rspec"
end
