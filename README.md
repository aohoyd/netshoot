## cdbg: a Docker + Kubernetes network trouble-shooting swiss-army container

```
 ██████╗██████╗ ██████╗  ██████╗
██╔════╝██╔══██╗██╔══██╗██╔════╝
██║     ██║  ██║██████╔╝██║  ███╗
██║     ██║  ██║██╔══██╗██║   ██║
╚██████╗██████╔╝██████╔╝╚██████╔╝
 ╚═════╝╚═════╝ ╚═════╝  ╚═════╝
```

**Purpose:** Docker and Kubernetes network troubleshooting can become complex. With proper understanding of how Docker and Kubernetes networking works and the right set of tools, you can troubleshoot and resolve these networking issues. The `cdbg` container has a set of powerful networking troubleshooting tools that can be used to troubleshoot Docker networking issues. Along with these tools come a set of use-cases that show how this container can be used in real-world scenarios.

**Network Namespaces:** Before starting to use this tool, it's important to go over one key topic: **Network Namespaces**. Network namespaces provide isolation of the system resources associated with networking. Docker uses network and other type of namespaces (`pid`,`mount`,`user`..etc) to create an isolated environment for each container. Everything from interfaces, routes, and IPs is completely isolated within the network namespace of the container. 

Kubernetes also uses network namespaces. Kubelets creates a network namespace per pod where all containers in that pod share that same network namespace (eths,IP, tcp sockets...etc). This is a key difference between Docker containers and Kubernetes pods.

Cool thing about namespaces is that you can switch between them. You can enter a different container's network namespace, perform some troubleshooting on its network's stack with tools that aren't even installed on that container. Additionally, `cdbg` can be used to troubleshoot the host itself by using the host's network namespace. This allows you to perform any troubleshooting without installing any new packages directly on the host or your application's package. 

## cdbg with Docker

* **Container's Network Namespace:** If you're having networking issues with your application's container, you can launch `cdbg` with that container's network namespace like this:

    `$ docker run -it --net container:<container_name> nicolaka/netshoot`

* **Host's Network Namespace:** If you think the networking issue is on the host itself, you can launch `cdbg` with that host's network namespace:

    `$ docker run -it --net host nicolaka/netshoot`

* **Network's Network Namespace:** If you want to troubleshoot a Docker network, you can enter the network's namespace using `nsenter`. This is explained in the `nsenter` section below.

## cdbg with Docker Compose

You can easily deploy `cdbg` using Docker Compose using something like this:

```
version: "3.6"
services:
  tcpdump:
    image: nicolaka/netshoot
    depends_on:
      - nginx
    command: tcpdump -i eth0 -w /data/nginx.pcap
    network_mode: service:nginx
    volumes:
      - $PWD/data:/data

  nginx:
    image: nginx:alpine
    ports:
      - 80:80
```

## cdbg with Kubernetes

* if you want to debug using an [ephemeral container](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container-example) in an existing pod:

    `$ kubectl debug mypod -it --image=nicolaka/netshoot`

* if you want to spin up a throw away pod for debugging.

    `$ kubectl run tmp-shell --rm -i --tty --image nicolaka/netshoot`

* if you want to spin up a container on the host's network namespace.

    `$ kubectl run tmp-shell --rm -i --tty --overrides='{"spec": {"hostNetwork": true}}'  --image nicolaka/netshoot`

* if you want to use cdbg as a sidecar container to troubleshoot your application container

 ```
    $ cat cdbg-sidecar.yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata:
        name: nginx-cdbg
        labels:
            app: nginx-cdbg
    spec:
    replicas: 1
    selector:
        matchLabels:
            app: nginx-cdbg
    template:
        metadata:
        labels:
            app: nginx-cdbg
        spec:
            containers:
            - name: nginx
            image: nginx:1.14.2
            ports:
                - containerPort: 80
            - name: cdbg
            image: aohoyd/cdbg
            command: ["/bin/bash"]
            args: ["-c", "while true; do ping localhost; sleep 60;done"]

    $ kubectl apply -f cdbg-sidecar.yaml
      deployment.apps/nginx-cdbg created

    $ kubectl get pod
NAME                          READY   STATUS    RESTARTS   AGE
nginx-cdbg-7f9c6957f8-kr8q6   2/2     Running   0          4m27s

    $ kubectl exec -it nginx-cdbg-7f9c6957f8-kr8q6 -c cdbg -- /bin/zsh
     ██████╗██████╗ ██████╗  ██████╗
    ██╔════╝██╔══██╗██╔══██╗██╔════╝
    ██║     ██║  ██║██████╔╝██║  ███╗
    ██║     ██║  ██║██╔══██╗██║   ██║
    ╚██████╗██████╔╝██████╔╝╚██████╔╝
     ╚═════╝╚═════╝ ╚═════╝  ╚═════╝

    Welcome to cdbg! (github.com/aohoyd/cdbg)


    nginx-cdbg-7f9c6957f8-kr8q6 $ 
 ```

## The cdbg kubectl plugin

To easily troubleshoot networking issues in your k8s environment, you can leverage the [Netshoot Kubectl Plugin](https://github.com/nilic/kubectl-netshoot) (shout out to Nebojsa Ilic for creating it!). Using this kubectl plugin, you can easily create ephemeral `cdbg` containers to troubleshoot existing pods, k8s controller or worker nodes. To install the plugin, follow [these steps](https://github.com/nilic/kubectl-netshoot#installation).

Sample Usage:

```
# spin up a throwaway pod for troubleshooting
kubectl netshoot run tmp-shell

# debug using an ephemeral container in an existing pod
kubectl netshoot debug my-existing-pod

# create a debug session on a node
kubectl netshoot debug node/my-node
```



**Network Problems** 

Many network issues could result in application performance degradation. Some of those issues could be related to the underlying networking infrastructure(underlay). Others could be related to misconfiguration at the host or Docker level. Let's take a look at common networking issues:

* latency
* routing 
* DNS resolution
* firewall 
* incomplete ARPs

To troubleshoot these issues, `cdbg` includes a set of powerful tools as recommended by this diagram. 

![](http://www.brendangregg.com/Perf/linux_observability_tools.png)


**Included Packages:** The following packages and binaries are included in `cdbg`:

    apache2-utils \
    bash \
    bind-tools \
    bird \
    bridge-utils \
    busybox-extras \
    conntrack-tools \
    curl \
    dhcping \
    drill \
    ethtool \
    file \
    fping \
    iftop \
    iperf \
    iperf3 \
    iproute2 \
    ipset \
    iptables \
    iptraf-ng \
    iputils \
    ipvsadm \
    httpie \
    jq \
    libc6-compat \
    liboping \
    ltrace \
    mtr \
    net-snmp-tools \
    netcat-openbsd \
    nftables \
    ngrep \
    nmap \
    nmap-nping \
    nmap-scripts \
    openssl \
    py3-pip \
    py3-setuptools \
    scapy \
    socat \
    speedtest-cli \
    openssh \
    oh-my-zsh \
    strace \
    tcpdump \
    tcptraceroute \
    trippy \
    tshark \
    util-linux \
    vim \
    git \
    zsh \
    websocat \
    swaks \
    perl-crypt-ssleay \
    perl-net-ssleay

Additionally, the following binaries are included:

    ctop
    calicoctl
    termshark
    grpcurl
    fortio

## **Sample Use-cases**

### iperf

Purpose: test networking performance between two containers/hosts.

Example:

```
$ docker network create -d bridge perf-test
$ docker run -d --rm --net perf-test --name perf-test-a nicolaka/netshoot iperf -s -p 9999
$ docker run -it --rm --net perf-test --name perf-test-b nicolaka/netshoot iperf -c perf-test-a -p 9999
```

### tcpdump

**tcpdump** is a powerful and common packet analyzer that runs under the command line. It allows the user to display TCP/IP and other packets being transmitted or received over an attached network interface.

```
$ docker run -it --net container:perf-test-a nicolaka/netshoot
/ # tcpdump -i eth0 port 9999 -c 1 -Xvv
```

### netstat

Purpose: `netstat` is a useful tool for checking your network configuration and activity.

```
$ docker run -it --net container:perf-test-a nicolaka/netshoot
/ # netstat -tulpn
```

### nmap

`nmap` ("Network Mapper") is an open source tool for network exploration and security auditing. It is very useful for scanning to see which ports are open between a given set of hosts.

```
$ docker run -it --privileged nicolaka/netshoot nmap -p 12376-12390 -dd 172.31.24.25
```

### iftop

Purpose: iftop does for network usage what top does for CPU usage. It listens to network traffic on a named interface and displays a table of current bandwidth usage by pairs of hosts.

```
$ docker run -it --net container:perf-test-a nicolaka/netshoot iftop -i eth0
```

### drill

Purpose: drill is a tool to designed to get all sorts of information out of the DNS.

```
$ docker run -it --net container:perf-test-a nicolaka/netshoot drill -V 5 perf-test-b
```

### netcat

Purpose: a simple Unix utility that reads and writes data across network connections, using the TCP or UDP protocol. It's useful for testing and troubleshooting TCP/UDP connections. `netcat` can be used to detect if there's a firewall rule blocking certain ports.

```
$ docker network create -d bridge my-br
$ docker run -d --rm --net my-br --name service-a nicolaka/netshoot nc -l 8080
$ docker run -it --rm --net my-br --name service-b nicolaka/netshoot nc -vz service-a 8080
```

### iproute2

Purpose: a collection of utilities for controlling TCP / IP networking and traffic control in Linux.

```
$ docker run -it --net host nicolaka/netshoot
/ # ip route show
/ # ip neigh show
```

### nsenter

Purpose: `nsenter` is a powerful tool allowing you to enter into any namespaces. `nsenter` is available inside `cdbg` but requires `cdbg` to be run as a privileged container. Additionally, you may want to mount the `/var/run/docker/netns` directory to be able to enter any network namespace including bridge networks.

```
$ docker run -it --rm -v /var/run/docker/netns:/var/run/docker/netns --privileged=true nicolaka/netshoot
/ # cd /var/run/docker/netns/
/var/run/docker/netns # ls
/ # nsenter --net=/var/run/docker/netns/<namespace> sh
```

### CTOP

ctop is a free open source, simple and cross-platform top-like command-line tool for monitoring container metrics in real-time. It allows you to get an overview of metrics concerning CPU, memory, network, I/O for multiple containers and also supports inspection of a specific container.

```
$ docker run -it --rm -v /var/run/docker.sock:/var/run/docker.sock nicolaka/netshoot ctop
```

### Termshark

Termshark is a terminal user-interface for tshark. It allows user to read pcap files or sniff live interfaces with Wireshark's display filters.

```
$ docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW -it nicolaka/netshoot termshark -i eth0 icmp
$ docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW -v /tmp/ipv4frags.pcap:/tmp/ipv4frags.pcap -it nicolaka/netshoot termshark -r /tmp/ipv4frags.pcap
```

### Swaks

Swaks (Swiss Army Knife for SMTP) is a featureful, flexible, scriptable, transaction-oriented SMTP test tool. It is free to use and licensed under the GNU GPLv2.

```
swaks --to user@example.com \
  --from fred@example.com --h-From: '"Fred Example" <fred@example.com>' \
  --auth CRAM-MD5 --auth-user me@example.com \
  --header-X-Test "test email" \
  --tls \
  --data "Example body"
```

### Grpcurl

grpcurl is a command-line tool that lets you interact with gRPC servers. It's basically curl for gRPC servers.

```
grpcurl grpc.server.com:443 my.custom.server.Service/Method
# no TLS
grpcurl -plaintext grpc.server.com:80 my.custom.server.Service/Method
```

### Fortio

Fortio is a fast, small, reusable, embeddable go library as well as a command line tool and server process, the server includes a simple web UI and REST API to trigger run and see graphical representation of the results.

```
$ fortio load http://www.google.com
```

## Contribution

Feel free to contribute networking troubleshooting tools and use-cases by opening PRs. If you would like to add any package, please follow these steps:

* In the PR, please include some rationale as to why this tool is useful to be included in cdbg. 
     > Note: If the functionality of the tool is already addressed by an existing tool, I might not accept the PR
* Change the Dockerfile to include the new package/tool
* If you're building the tool from source, make sure you leverage the multi-stage build process and update the `build/fetch_binaries.sh` script 
* Update the README's list of included packages AND include a section on how to use the tool
* If the tool you're adding supports multi-platform, please make sure you highlight that.

## Updating packages

Run `make update` to check the custom melange packages in `packages/` for newer upstream versions on GitHub. It iterates over every package YAML and runs `./update-package.sh <path/to/package.yaml>` on each (you can also run the script on a single package directly). For each package it shows the current → latest version and a compare link, then prompts `y/N`. If a package has no version set yet (e.g. one you just added), it seeds the version with the latest available release. On `y` it edits the YAML in place: it bumps the version and resets `epoch` to 0, then for fetch-based packages recomputes the per-arch `sha256`, and for git-checkout packages updates the pinned commit. Edits are atomic — on any failure the original file is restored and you see an `update failed, reverted` message.

Prerequisites:

* the [`gh`](https://cli.github.com) CLI, authenticated (`gh auth login`)
* `yq`, `jq`, `curl`, and a sha256 tool (`shasum` or `sha256sum`) installed

Only packages with `update.enabled: true` are processed; others (those with `update.enabled: false` or no `update:` block) print an `updates not enabled (skipping)` message and are skipped, as are packages whose latest upstream tag is non-numeric or a pre-release.


