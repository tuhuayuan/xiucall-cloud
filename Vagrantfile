# -*- mode: ruby -*-
# # vi: set ft=ruby :

require 'fileutils'
require 'tempfile'

Vagrant.require_version ">= 1.6.0"

# default config
$update_channel = "stable"
$master_count = 1
$master_vm_memory = 1024
$worker_count = 1
$worker_vm_memory = 1024
$vm_cpu = 1

CONFIG = File.expand_path("config.rb")
if File.exist?(CONFIG)
  require CONFIG
end

# master cluster ip, apiserver
MASTER_CLUSTER_IP="10.3.0.1"

# cloud-init config script
MASTER_CLOUD_CONFIG_PATH = File.expand_path("./vagrant/init-master.sh")
WORKER_CLOUD_CONFIG_PATH = File.expand_path("./vagrant/init-worker.sh")

# Generate private network ips
def getMasterIp(num)
  return "172.17.4.#{num+100}"
end

def getWorkerIp(num)
  return "172.17.4.#{num+200}"
end

# include all master private ip
master_ips = [*1..$master_count].map{ |i| getMasterIp(i) }
worker_ips = [*1..$worker_count].map{ |i| getWorkerIp(i) }
cluster_domain = "cluster.local"

# All nodes start etcd daemon and join together at setup.
# Generate etcd cluster static configs
etcd_node_index=1
etcd_ips = master_ips + worker_ips
initial_etcd_cluster = etcd_ips.map.with_index{ |ip, i| "node#{i+1}=http://#{ip}:2380" }.join(",")
etcd_endpoints = etcd_ips.map.with_index{ |ip, i| "http://#{ip}:2379" }.join(",")

# Generate root CA
system("mkdir -p ssl && ./lib/init-ssl-ca ssl") or abort ("failed generating SSL artifacts")

# Generate admin key/cert
system("./lib/init-ssl ssl admin kube-admin") or abort("failed generating admin SSL artifacts")

# Provision ssl file
def provisionMachineSSL(machine,bsn,cn,ips)
  str_file = "ssl/#{cn}.tar"
  str_ip = ips.map.with_index { |ip, i| "IP.#{i+1}=#{ip}"}.join(",")
  system("./lib/init-ssl ssl #{bsn} #{cn} #{str_ip}") or abort("failed generating #{cn} SSL artifacts")
  machine.vm.provision :file, :source => str_file, :destination => "/tmp/ssl.tar"
  machine.vm.provision :shell, :inline => "mkdir -p /etc/kubernetes/ssl && tar -C /etc/kubernetes/ssl -xf /tmp/ssl.tar", :privileged => true
end

# Provision manifests file
def provisionManifests(machine)
  tar_file = "./tmp/manifests.tar"
  system("tar -cf #{tar_file} ./manifests")
  machine.vm.provision :file, :source => tar_file, :destination => "/tmp/manifests.tar"
  machine.vm.provision :shell, :inline => "mkdir -p /srv/kubernetes/manifests && tar -C /srv/kubernetes/  -xf /tmp/manifests.tar", :privileged => true
end

Vagrant.configure("2") do |config|
  # always use Vagrant's insecure key
  config.ssh.insert_key = false

  config.vm.box = "coreos-%s" % $update_channel
  config.vm.box_version = ">= 1010.5.0"
  config.vm.box_url = "http://%s.release.core-os.net/amd64-usr/current/coreos_production_vagrant.json" % $update_channel

  ["vmware_fusion", "vmware_workstation"].each do |vmware|
    config.vm.provider vmware do |v, override|
      override.vm.box_url = "http://%s.release.core-os.net/amd64-usr/current/coreos_production_vagrant_vmware_fusion.json" % $update_channel
    end
  end

  config.vm.provider :virtualbox do |v|
    # On VirtualBox, we don't have guest additions or a functional vboxsf
    # in CoreOS, so tell Vagrant that so it can be smarter.
    v.check_guest_additions = false
    v.functional_vboxsf     = false
  end

  # plugin conflict
  if Vagrant.has_plugin?("vagrant-vbguest") then
    config.vbguest.auto_update = false
  end

  ["vmware_fusion", "vmware_workstation"].each do |vmware|
    config.vm.provider vmware do |v|
      v.vmx['numvcpus'] = $vm_cpu
      v.gui = false
    end
  end

  config.vm.provider :virtualbox do |vb|
    vb.cpus = $vm_cpu
    vb.gui = false
  end

  (1..$master_count).each do |i|
    config.vm.define vm_name = "master-%d" % i do |master|

      env_file = Tempfile.new('env_file')
      env_file.write("ETCD_ENDPOINTS=#{etcd_endpoints}\n")
      env_file.write("ETCD_INITIAL_CLUSTER=#{initial_etcd_cluster}\n")
      env_file.write("ETCD_NAME=node#{etcd_node_index}\n")
      env_file.write("CLUSTER_DOMAIN=#{cluster_domain}")
      etcd_node_index += 1
      env_file.close

      master.vm.hostname = vm_name

      ["vmware_fusion", "vmware_workstation"].each do |vmware|
        master.vm.provider vmware do |v|
          v.vmx['memsize'] = $master_vm_memory
        end
      end

      master.vm.provider :virtualbox do |vb|
        vb.memory = $master_vm_memory
      end

      config.vm.synced_folder ENV['HOME'], ENV['HOME'], id: "home", :nfs => true, :mount_options => ['nolock,vers=3,udp']

      master_ip = getMasterIp(i)
      master.vm.network :private_network, ip: master_ip

      # Each controller gets the same cert
      provisionMachineSSL(master,"apiserver","kube-master-#{master_ip}",master_ips+[MASTER_CLUSTER_IP])
      
      # Upload manifest files
      provisionManifests(master)

      master.vm.provision :file, :source => env_file, :destination => "/tmp/coreos-kube-options.env"
      master.vm.provision :shell, :inline => "mkdir -p /run/coreos-kubernetes && mv /tmp/coreos-kube-options.env /run/coreos-kubernetes/options.env", :privileged => true

      master.vm.provision :file, :source => MASTER_CLOUD_CONFIG_PATH, :destination => "/tmp/vagrantfile-user-data"
      master.vm.provision :shell, :inline => "mv /tmp/vagrantfile-user-data /var/lib/coreos-vagrant/", :privileged => true
    end
  end

  (1..$worker_count).each do |i|
    config.vm.define vm_name = "worker-%d" % i do |worker|
      worker.vm.hostname = vm_name

      env_file = Tempfile.new('env_file')
      env_file.write("ETCD_ENDPOINTS=#{etcd_endpoints}\n")
      env_file.write("ETCD_INITIAL_CLUSTER=#{initial_etcd_cluster}\n")
      env_file.write("MASTER_ENDPOINT=https://#{master_ips[0]}\n")
      env_file.write("ETCD_NAME=node#{etcd_node_index}\n")
      env_file.write("CLUSTER_DOMAIN=#{cluster_domain}")
      etcd_node_index += 1
      env_file.close

      ["vmware_fusion", "vmware_workstation"].each do |vmware|
        worker.vm.provider vmware do |v|
          v.vmx['memsize'] = $worker_vm_memory
        end
      end

      worker.vm.provider :virtualbox do |vb|
        vb.memory = $worker_vm_memory
      end

      worker_ip = getWorkerIp(i)
      worker.vm.network :private_network, ip: worker_ip

      # Each controller gets the same cert
      provisionMachineSSL(worker,"worker","kube-worker-#{worker_ip}",[worker_ip])

      # Upload manifest files
      provisionManifests(worker)

      worker.vm.provision :file, :source => env_file, :destination => "/tmp/coreos-kube-options.env"
      worker.vm.provision :shell, :inline => "mkdir -p /run/coreos-kubernetes && mv /tmp/coreos-kube-options.env /run/coreos-kubernetes/options.env", :privileged => true

      worker.vm.provision :file, :source => WORKER_CLOUD_CONFIG_PATH, :destination => "/tmp/vagrantfile-user-data"
      worker.vm.provision :shell, :inline => "mv /tmp/vagrantfile-user-data /var/lib/coreos-vagrant/", :privileged => true
    end
  end

end
