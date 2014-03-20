#
# Cookbook Name:: openresty
# Recipe:: default
#
# Author:: Panagiotis Papadomitsos (<pj@ezgr.net>)
# Author:: Stephen Delano (<stephen@opscode.com>)
#
# Copyright 2012, Panagiotis Papadomitsos
# Based heavily on Opscode's original nginx cookbook (https://github.com/opscode-cookbooks/nginx)
#
# Licensed under the Apache License, Version 2.0 (the 'License');
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an 'AS IS' BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/version_constraint'

kernel_supports_aio = Chef::VersionConstraint.new('>= 2.6.22').include?(node['kernel']['release'].split('-').first)
restart_after_update = node['openresty']['restart_after_update'] ? ' && $( kill -QUIT `pgrep -U root openresty` || true )' : ''

include_recipe 'build-essential'

src_filepath  = "#{Chef::Config['file_cache_path'] || '/tmp'}/ngx_openresty-#{node['openresty']['source']['version']}.tar.gz"

packages = value_for_platform_family(
  ['rhel','fedora','amazon','scientific'] => [ 'openssl-devel', 'readline-devel', 'ncurses-devel' ],
  'debian' => [ 'libperl-dev', 'libssl-dev', 'libreadline-dev', 'libncurses5-dev']
)

# Enable AIO for newer kernels
packages |= value_for_platform_family(
    ['rhel','fedora','amazon','scientific'] => [ 'libatomic_ops-devel' ],
    'debian' => [ 'libatomic-ops-dev', 'libaio1', 'libaio-dev' ]
) if kernel_supports_aio

packages.each do |devpkg|
  package devpkg
end

remote_file node['openresty']['source']['url'] do
  source node['openresty']['source']['url']
  checksum node['openresty']['source']['checksum']
  path src_filepath
  backup false
end

cookbook_file "#{Chef::Config['file_cache_path']}/openresty-rate-limit-correct-error-code.patch" do
  source 'openresty-rate-limit-correct-error-code.patch'
  owner 'root'
  group 'root'
  mode 00644
  only_if { node['openresty']['source']['limit_code_patch'] }
end

node.default['openresty_force_recompile'] = false
node.default['openresty_configure_flags'] = node['openresty']['source']['default_configure_flags'] | node['openresty']['configure_flags']

# Custom PCRE
if node['openresty']['custom_pcre']
  pcre_path = "#{Chef::Config['file_cache_path'] || '/tmp'}/pcre-#{node['openresty']['pcre']['version']}"
  pcre_opts = 'export PCRE_CONF_OPT="--enable-utf8 --enable-unicode-properties" && '
  remote_file "#{pcre_path}.tar.bz2" do
    owner 'root'
    group 'root'
    mode 00644
    source node['openresty']['pcre']['url']
    checksum node['openresty']['pcre']['checksum']
    action :create_if_missing
  end
  execute 'openresty-extract-pcre' do
    user 'root'
    cwd(Chef::Config['file_cache_path'] || '/tmp')
    command "tar xjf #{pcre_path}.tar.bz2"
    not_if { ::File.directory?(pcre_path) }
  end
  node.default['openresty_configure_flags'] |= [ "--with-pcre=#{pcre_path}", '--with-pcre-jit' ]
else
  pcre_opts = ''
  value_for_platform_family(
    ['rhel','fedora','amazon','scientific'] => [ 'pcre', 'pcre-devel' ],
    'debian' => ['libpcre3', 'libpcre3-dev' ]
  ).each do |pkg|
    package pkg
  end
  node.default['openresty_configure_flags'] |= [ '--with-pcre' ]
end

# System flags
node.default['openresty_configure_flags'] |= [ '--with-file-aio', '--with-libatomic' ]  if kernel_supports_aio
node.default['openresty_configure_flags'] |= [ '--with-ipv6' ]                          if node['openresty']['ipv6']

# OpenResty extra modules
node.default['openresty_configure_flags'] |= [ '--with-luajit' ]                        if node['openresty']['or_modules']['luajit']
node.default['openresty_configure_flags'] |= [ '--with-http_iconv_module' ]             if node['openresty']['or_modules']['iconv']

if node['openresty']['or_modules']['postgres']
  include_recipe 'postgresql::client'
  node.default['openresty_configure_flags'] |= [ '--with-http_postgres_module' ]
end

if node['openresty']['or_modules']['drizzle']
  drizzle = value_for_platform_family(
    ['rhel','fedora','amazon','scientific'] => 'libdrizzle-devel',
    'debian' => 'libdrizzle-dev'
  )
  package drizzle
  node.default['openresty_configure_flags'] |= [ '--with-http_drizzle_module' ]
end

node['openresty']['modules'].each do |ngx_module|
  include_recipe "openresty::#{ngx_module}"
end

node['openresty']['extra_modules'].each do |ngx_module|
  include_recipe ngx_module
end

configure_flags = node.default['openresty_configure_flags']
openresty_force_recompile = node.default['openresty_force_recompile']

# The 3 first version numbers of OpenResty is the actual NGINX version. It's a bit ugly but it works...
openresty_version = node['openresty']['source']['version'].split('.')[0...-1].join('.')
if node['openresty']['source']['limit_code_patch']
  limit_code_patch = <<-EOT
  cd bundle/nginx-#{openresty_version} &&
  patch -p1 < #{Chef::Config['file_cache_path']}/openresty-rate-limit-correct-error-code.patch &&
  cd ../../ &&
  EOT
else
  patch = ''
end

ruby_block 'persist-openresty-configure-flags' do
  block { node.set['openresty']['persisted_configure_flags'] = configure_flags }
  action :nothing
end

bash 'compile_openresty_source' do
  cwd ::File.dirname(src_filepath)
  code <<-EOH
    tar zxf #{::File.basename(src_filepath)} -C #{::File.dirname(src_filepath)} &&
    cd ngx_openresty-#{node['openresty']['source']['version']} &&
    #{limit_code_patch}
    #{pcre_opts}
    ./configure #{node.default['openresty_configure_flags'].join(' ')} &&
    make -j#{node['cpu']['total']} && make install #{restart_after_update}
  EOH

  # OpenResty configure args massaging due to the configure script adding its own arguments along our custom ones
  if Chef::Config[:solo]
    not_if do
      openresty_force_recompile == false &&
        node.automatic_attrs['openresty'] &&
        node.automatic_attrs['openresty']['version'] == node['openresty']['source']['version'] &&
        (configure_flags.reject{ |f| f =~ /with-http_(drizzle|iconv|postgres)_module/ } &
          node.automatic_attrs['openresty']['configure_arguments'].
          reject{ |f| f =~ /(--add-module=\.\.\/)/ }.
          map{ |f| f =~ /luajit/ ? '--with-luajit' : f }.
          sort).size == configure_flags.reject{ |f| f =~ /with-http_(drizzle|iconv|postgres)_module/ }.size
    end
  else
    not_if do
      openresty_force_recompile == false &&
        node.automatic_attrs['openresty'] &&
        node.automatic_attrs['openresty']['version'] == node['openresty']['source']['version'] &&
        node['openresty']['persisted_configure_flags'] &&
        node['openresty']['persisted_configure_flags'].sort == configure_flags.sort
    end
  end

  notifies :create, 'ruby_block[persist-openresty-configure-flags]'
end

node.default.delete('openresty_configure_flags')
node.default.delete('openresty_force_recompile')
