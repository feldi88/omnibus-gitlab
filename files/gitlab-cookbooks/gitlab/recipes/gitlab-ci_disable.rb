#
# Copyright:: Copyright (c) 2012 Opscode, Inc.
# Copyright:: Copyright (c) 2015 GitLab B.V.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

ci_dependent_services = []
ci_dependent_services << "ci-unicorn" if OmnibusHelper.should_notify?("ci-unicorn")
ci_dependent_services << "ci-sidekiq" if OmnibusHelper.should_notify?("ci-sidekiq")
ci_dependent_services << "ci-redis" if OmnibusHelper.should_notify?("ci-redis")
accounts = AccountHelper.new(node)
gitlab_user = accounts.gitlab_user
gitlab_ci_user = accounts.gitlab_ci_user
gitlab_ci_dir = "#{node['gitlab']['gitlab-ci']['dir']}-legacy"
gitlab_ci_static_dir = "/opt/gitlab/etc/gitlab-ci"
gitlab_ci_etc_dir = File.join(gitlab_ci_dir, "etc")
gitlab_ci_log_dir = File.join(gitlab_ci_dir, "log")

ci_nginx_vars = node['gitlab']['ci-nginx'].to_hash

if ci_nginx_vars['listen_https'].nil?
  ci_nginx_vars['https'] = node['gitlab']['gitlab-ci']['gitlab_ci_https']
else
  ci_nginx_vars['https'] = ci_nginx_vars['listen_https']
end

nginx_conf_dir = File.join(node['gitlab']['nginx']['dir'], "conf")
gitlab_ci_http_config = File.join(nginx_conf_dir, "gitlab-ci-http.conf")

if node["gitlab"]['gitlab-ci']["enable"]
  template gitlab_ci_http_config do
    source "nginx-gitlab-ci-http.conf.erb"
    owner "root"
    group "root"
    mode "0644"
    variables(ci_nginx_vars.merge(
      {
        :fqdn => node['gitlab']['gitlab-ci']['gitlab_ci_host'],
        :port => node['gitlab']['gitlab-ci']['gitlab_ci_port'],
        :socket => node['gitlab']['ci-unicorn']['socket'],
        :gitlab_fqdn => CiHelper.gitlab_server_fqdn
      }
    ))
    notifies :restart, 'service[nginx]' if OmnibusHelper.should_notify?("nginx")
  end

  [ gitlab_ci_dir, gitlab_ci_etc_dir, gitlab_ci_log_dir, gitlab_ci_static_dir ].each do |dir|
    directory dir do
      owner gitlab_ci_user
      recursive true
    end
  end

  link "#{node['package']['install-dir']}/embedded/service/gitlab-ci/log" do
    to gitlab_ci_log_dir
  end

  template File.join(gitlab_ci_static_dir, "gitlab-ci-rc")

  env_dir File.join(gitlab_ci_static_dir, 'env') do
    variables(
      {
        'HOME' => File.join(gitlab_ci_dir, "home"),
        'RAILS_ENV' => node['gitlab']['gitlab-ci']['environment'],
      }.merge(node['gitlab']['gitlab-ci']['env'])
    )
  end

  template_symlink File.join(gitlab_ci_etc_dir, "database.yml") do
    link_from File.join("/opt/gitlab/embedded/service/gitlab-ci", "config/database.yml")
    source "database.yml.erb"
    owner "root"
    group "root"
    mode "0644"
    variables node['gitlab']['gitlab-ci'].to_hash
    helpers SingleQuoteHelper
  end

  template_symlink File.join(gitlab_ci_etc_dir, "secrets.yml") do
    link_from File.join("/opt/gitlab/embedded/service/gitlab-ci", "config/secrets.yml")
    source "secrets.yml.erb"
    owner "root"
    group "root"
    mode "0644"
    variables node['gitlab']['gitlab-ci'].to_hash
    helpers SingleQuoteHelper
  end

  node.override["gitlab"]['nginx']["gitlab_ci_http_config"] = gitlab_ci_http_config
  node.override["gitlab"]['gitlab-ci']["enable"] = false
else
  template gitlab_ci_http_config do
    source "nginx-gitlab-ci-http.conf.erb"
    action :delete
  end

  node.override["gitlab"]['nginx']["gitlab_ci_http_config"] = nil
end

if OmnibusHelper.user_exists?(gitlab_ci_user)
  directory node['gitlab']['gitlab-ci']['backup_path'] do
    owner gitlab_ci_user
    mode '0755'
    recursive true
  end

  # Stop and disable services
  ci_dependent_services.each do |ci_service|
    service ci_service do
      action :stop
    end

    include_recipe "gitlab::#{ci_service}_disable"

    if node["gitlab"][ci_service]["enable"]
      node.override["gitlab"][ci_service]["enable"] = false
    end
  end
end

if node["gitlab"]['gitlab-ci']["enable"]
  node.override["gitlab"]['gitlab-ci']["enable"] = false
end
