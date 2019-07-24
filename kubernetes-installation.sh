#!/bin/bash

# Kurulum için güncel repoları çekiyoruz
sudo apt-get update
sudo apt-get upgrade -y

# Daha önce kurulu kubernet var ise tüm config dosyaları ile birlikte siliyoruz (Daha önce kurulan dockerlar hariç)
sudo systemctl stop kubelet
sudo kubeadm reset --force
sudo rm -rf /etc/kubernetes/*
sudo systemctl daemon-reload
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
sudo rm -rf $HOME/.kube/*
sudo rm -rf /var/lib/etcd
sudo rm -rf /var/lib/cni/
sudo kill -9 $(lsof -t -i:8002)
sudo kill -9 $(lsof -t -i:8080)

# Eğer sisteminizde kurulu bir docker yok ise kuruyoruz
sudo apt-get install -y docker.io
sudo systemctl start docker
sudo systemctl enable docker

# Kubernet kurulumunu yapıyoruz
sudo apt-get install -y curl
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
# Kurulum için güncel repoları tekrar çekiyoruz
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y kubeadm

# Tanımlı bir swap alanı var ise kapatıyoruz, restart sonrasında sorun yaşanmaması için fstab'dan kaldırıyoruz
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Kişisel kullanım için wifi veya ethernet kablosu geçişlerinde veya ağ değişikliğinden dolayı ip sorunlarını önlemek için wlan oluşturuyoruz 
# enp3s0 ve wlo1 benim bilgisayarımdaki network isimleridir sizde örneğin eth0 ve wlan0 var ise aşağıdaki config dosyasını buna göre düzenlemelisiniz!
sudo mkdir -p /etc/netplan-olds/
sudo mv /etc/netplan/*.yaml /etc/netplan-olds/
sudo bash -c 'cat << EOF > /etc/netplan/kubernet.yaml
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    enp3s0:
      dhcp4: no
    wlo1:
      dhcp4: yes

  bridges:
    kubernet-bridge:
      interfaces: [enp3s0, wlo1]
      dhcp4: no
      addresses: [100.100.100.100/24]
      nameservers:
        addresses: [8.8.8.8, 4.4.4.4]
EOF'
sleep 30s
sudo netplan apply
sudo netplan apply
sudo /etc/init.d/networking restart

# Kubernet ayağa kaldırılıyor
sudo kubeadm init --apiserver-advertise-address=100.100.100.100
#--pod-network-cidr=40.168.0.0/16 --ignore-preflight-errors=all
sudo kubeadm token list
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=$HOME/.kube/config

# Kubernet dashboard kurulumu yapılıyor
kubectl apply -f kubernetes-dashboard.yaml
kubectl create serviceaccount dashboard -n default
kubectl create clusterrolebinding dashboard-admin -n default --clusterrole=cluster-admin --serviceaccount=default:dashboard
# Kubernet dashboard token 'ey' ile başlıyor bunu bir yere not edelim
echo "\n-------------------------------"
kubectl get secret $(kubectl get serviceaccount dashboard -o jsonpath="{.secrets[0].name}") -o jsonpath="{.data.token}" | base64 --decode
echo "\n-------------------------------\n"

# Kubernet network için Weave.net kurulumu yapılıyor
sudo sysctl net.bridge.bridge-nf-call-iptables=1
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"

# WeaveScope kurulumu yapılıyor
sudo curl -L git.io/scope -o /usr/local/bin/scope
sudo chmod a+x /usr/local/bin/scope
nohup scope launch &

# Kubernet dashboard 8002 portundan çalıştırılıyor, erişim linki aşağıdaki gibi olacaktır
# http://localhost:8002/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/#!/login 
kubectl taint nodes --all node-role.kubernetes.io/master-
kubectl --kubeconfig=$HOME/.kube/config proxy -p 8002 &

sleep 60s

# Helm kurulumu yapılıyor ve daha önce kurulu ise resetleniyor
sudo snap install helm --classic
helm reset --force
helm init --upgrade
helm del --purge kubeapps

# Kubeapps için repo helm'e ekleniyor ve kuruluyor
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install --name kubeapps --namespace kubeapps bitnami/kubeapps

# Yukarıdaki komutun cevabı olarak aşağıdaki hatayı alıyorsanız aşağıdaki komutların girilmesi gerekiyor
# Error: namespaces "kubeapps" is forbidden: User "system:serviceaccount:kube-system:default" cannot get resource "namespaces" in API group "" in the namespace "kubeapps" hatasının çözümü için aşağıdaki komutlar girilmeli
kubectl create serviceaccount --namespace kube-system tiller
kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller"}}}}'
helm init --service-account tiller --upgrade
# Podların ayağa kalkmasını bekliyoruz
sleep 20s
# Kubeapps kurulumu için komutu tekrar çalıştırıyoruz
helm install --name kubeapps --namespace kubeapps bitnami/kubeapps

# Cluster Role tanımlaması yapılıyor
kubectl create serviceaccount kubeapps-operator
kubectl create clusterrolebinding kubeapps-operator --clusterrole=cluster-admin --serviceaccount=default:kubeapps-operator
# Kubeapps token 'ey' ile başlıyor bunu da bir yere not edelim
echo "\n-------------------------------"
kubectl get secret $(kubectl get serviceaccount kubeapps-operator -o jsonpath='{.secrets[].name}') -o jsonpath='{.data.token}' | base64 --decode
echo "\n-------------------------------\n"

# Kubeapps 8080 portundan çalıştırılıyor, erişim linki aşağıdaki gibi olacaktır
# http://127.0.0.1:8080/
sleep 30s
export POD_NAME=$(kubectl get pods --namespace kubeapps -l "app=kubeapps" -o jsonpath="{.items[0].metadata.name}")
kubectl port-forward --namespace kubeapps $POD_NAME 8080:8080 &




