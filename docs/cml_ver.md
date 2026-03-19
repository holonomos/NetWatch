# command line outputs

## 0.1

hussainmir@fedora:~/NetWatch$ egrep -c  '(vmx|svm)' /proc/cpuinfo
16
hussainmir@fedora:~/NetWatch$ lsmod | grep kvm
kvm_intel             561152  0
kvm                  1523712  1 kvm_intel
irqbypass              16384  1 kvm
hussainmir@fedora:~/NetWatch$ 

## 0.2



## 0.3




## 0.10
hussainmir@fedora:~/NetWatch$ vagrant box add fedora/40-cloud-base /home/hussainmir/Downloads/Fedora-Cloud-Base-Vagrant-libvirt-43-1.6.x86_64.vagrant.libvirt.box         
==> box: Box file was not detected as metadata. Adding it directly...
==> box: Adding box 'fedora/40-cloud-base' (v0) for provider: (amd64)
    box: Unpacking necessary files from: file:///home/hussainmir/Downloads/Fedora-Cloud-Base-Vagrant-libvirt-43-1.6.x86_64.vagrant.libvirt.box
==> box: Successfully added box 'fedora/40-cloud-base' (v0) for '(amd64)'!
hussainmir@fedora:~/NetWatch$ 
\

phase 3

hussainmir@fedora:~/NetWatch$ ip link show type bridge
3: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN mode DEFAULT group default 
    link/ether 52:97:f6:40:d4:72 brd ff:ff:ff:ff:ff:ff
5: br-mgmt: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 76:8f:32:d6:8e:d3 brd ff:ff:ff:ff:ff:ff
6: br000: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether e6:9f:79:fd:6f:3c brd ff:ff:ff:ff:ff:ff
7: br001: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 5a:7e:7f:d7:59:37 brd ff:ff:ff:ff:ff:ff
8: br002: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 62:83:2e:d9:3d:61 brd ff:ff:ff:ff:ff:ff
9: br003: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether a6:f9:6d:61:88:73 brd ff:ff:ff:ff:ff:ff
10: br004: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 3a:2b:0d:9c:d8:88 brd ff:ff:ff:ff:ff:ff
11: br005: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 4a:93:7f:ee:c8:c6 brd ff:ff:ff:ff:ff:ff
12: br006: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether e2:ca:de:42:46:e9 brd ff:ff:ff:ff:ff:ff
13: br007: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 9a:04:44:f4:fb:69 brd ff:ff:ff:ff:ff:ff
14: br008: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 26:40:e6:57:3b:f1 brd ff:ff:ff:ff:ff:ff
15: br009: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether fe:cb:04:6a:f5:7b brd ff:ff:ff:ff:ff:ff
16: br010: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 96:6f:e1:3b:ed:8a brd ff:ff:ff:ff:ff:ff
17: br011: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 5e:ad:d8:97:28:b1 brd ff:ff:ff:ff:ff:ff
18: br012: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 0e:75:cf:71:2e:6b brd ff:ff:ff:ff:ff:ff
19: br013: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 22:07:91:84:a5:54 brd ff:ff:ff:ff:ff:ff
20: br014: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 16:3b:c5:66:d1:9e brd ff:ff:ff:ff:ff:ff
21: br015: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 4e:02:c9:ff:3c:3b brd ff:ff:ff:ff:ff:ff
22: br016: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 02:4b:a2:fe:e9:47 brd ff:ff:ff:ff:ff:ff
23: br017: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 36:d8:70:d0:93:34 brd ff:ff:ff:ff:ff:ff
24: br018: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 1a:93:ad:62:ac:97 brd ff:ff:ff:ff:ff:ff
25: br019: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 32:cc:7e:bf:38:d4 brd ff:ff:ff:ff:ff:ff
26: br020: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 22:eb:ff:ff:de:74 brd ff:ff:ff:ff:ff:ff
27: br021: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 7a:19:8a:0d:aa:ec brd ff:ff:ff:ff:ff:ff
28: br022: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 3e:61:3f:db:41:06 brd ff:ff:ff:ff:ff:ff
29: br023: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 0a:f0:e6:f1:b2:d3 brd ff:ff:ff:ff:ff:ff
30: br024: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether e2:e5:04:64:50:af brd ff:ff:ff:ff:ff:ff
31: br025: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 1a:9f:cc:ff:9e:b0 brd ff:ff:ff:ff:ff:ff
32: br026: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 4e:1b:70:dc:db:e8 brd ff:ff:ff:ff:ff:ff
33: br027: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 96:05:0f:be:cc:ed brd ff:ff:ff:ff:ff:ff
34: br028: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 86:e4:e9:1c:90:6b brd ff:ff:ff:ff:ff:ff
35: br029: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether e2:44:f7:59:df:53 brd ff:ff:ff:ff:ff:ff
36: br030: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 26:78:2a:cb:17:59 brd ff:ff:ff:ff:ff:ff
37: br031: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether ce:86:76:c8:e3:40 brd ff:ff:ff:ff:ff:ff
38: br032: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether b6:cc:2f:40:63:c1 brd ff:ff:ff:ff:ff:ff
39: br033: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 96:8e:58:69:97:46 brd ff:ff:ff:ff:ff:ff
40: br034: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether d6:f6:8f:7e:e2:3d brd ff:ff:ff:ff:ff:ff
41: br035: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 1e:2c:4f:68:9b:31 brd ff:ff:ff:ff:ff:ff
42: br036: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether ca:88:93:c7:0a:16 brd ff:ff:ff:ff:ff:ff
43: br037: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether a2:97:4c:c0:89:8c brd ff:ff:ff:ff:ff:ff
44: br038: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether ca:46:60:b7:31:1c brd ff:ff:ff:ff:ff:ff
45: br039: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 42:2b:c2:ae:b4:77 brd ff:ff:ff:ff:ff:ff
46: br040: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether de:d6:7f:bb:cd:49 brd ff:ff:ff:ff:ff:ff
47: br041: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 6a:bf:cd:be:2d:31 brd ff:ff:ff:ff:ff:ff
48: br042: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 92:9d:5b:26:b5:22 brd ff:ff:ff:ff:ff:ff
49: br043: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 8e:ee:48:71:39:18 brd ff:ff:ff:ff:ff:ff
50: br044: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether ae:ab:20:21:78:ff brd ff:ff:ff:ff:ff:ff
51: br045: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether c2:88:cf:22:4f:36 brd ff:ff:ff:ff:ff:ff
52: br046: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 5e:90:67:92:ba:ff brd ff:ff:ff:ff:ff:ff
53: br047: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 6a:76:72:17:a1:c7 brd ff:ff:ff:ff:ff:ff
54: br048: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether ca:d1:ba:77:ac:d8 brd ff:ff:ff:ff:ff:ff
55: br049: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 82:fc:0e:ca:5a:e0 brd ff:ff:ff:ff:ff:ff
56: br050: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 4e:44:4e:8d:3e:4f brd ff:ff:ff:ff:ff:ff
57: br051: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 56:15:e0:f6:db:20 brd ff:ff:ff:ff:ff:ff
hussainmir@fedora:~/NetWatch$ 
