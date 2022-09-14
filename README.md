# Creating cluster for installing weka client instructions

<br/>

## Prerequisites
- openshift-install
  - currently using version 4.10.10
  - moving to newer version will require 2 updates:
    - `channel: "4.10"` in `performance_addon/pao.yaml`
    - docker image in `driver_toolkit/0000-weka-kvc-buildconfig-driver-container-namespace.yaml`
- oc
- AWS admin profile


## cluster creation
```commandline
mkdir cluster
cp install-config.yaml cluster
# replace in cluster/install-config.yaml COPY_PULL_SECRET_HERE and COPY_SSH_PUBLIC_KEY_HERE
# cluster creation usually takes about ~20M
AWS_PROFILE=AdminInsecure openshift-install create cluster --dir=cluster --log-level=debug
```
####error message of this kind can be ignored:
```doctest
ERROR
ERROR Error: Error deleting IAM Role (coreos-x5t7t-bootstrap-role): DeleteConflict: Cannot delete entity, must detach all policies first.
ERROR 	status code: 409, request id: f32ca5e6-7c6b-4e92-94bf-72b9715158ff
ERROR
ERROR
FATAL terraform destroy: failed to destroy using Terraform
```

## login to cluster
Note: need to wait a few minutes until login will work
if the openshift cluster isn't ready yet, you will get:
`error: couldn't get https://api.coreos.redhat.service.wekalab.io:6443/.well-known/oauth-authorization-server: unexpected response status 404
`
```commandline
oc login https://api.coreos.redhat.service.wekalab.io:6443 -u kubeadmin -p $(cat cluster/auth/kubeadmin-password)
```

## label worker node (we have only one worker)
```commandline
oc label node $(oc get nodes | grep worker | awk '{print $1}') node-role.kubernetes.io/worker-perf="" machineconfiguration.openshift.io/role=worker-perf
```

## create performance addon
```commandline
oc apply -f performance_addon/pao.yaml
```

## create performance profile
Note: need to wait for the command above to complete
If it isn't completed yet, you wil get:
```error: unable to recognize "performance_addon/profile_simple.yaml": no matches for kind "PerformanceProfile" in version "performance.openshift.io/v2"```

```commandline
oc apply -f performance_addon/profile_simple.yaml
```

## crate a pod with resources limit
```commandline
oc apply -f performance_addon/qos-pod.yaml
```

#### testing pod limit
Note: wait until the pod from the line above is in running state before running this.
```commandline
oc exec -it qos-demo -- /bin/bash -c " cat /proc/1/status | grep Cpus"
# should have:
# Cpus_allowed:	0003
# Cpus_allowed_list:	0-1
```

## creating driver toolkit:
```commandline
oc create -f driver_toolkit/0000-weka-kvc-buildconfig-driver-container-namespace.yaml
```

#### testing driver toolkit:
Note: wait until the pod from the line above is in running state before running this. It might take a few minutes.
When it is done, this command: `oc get pods -n weka-kmod-drivers`, should result with:
```
NAME                                READY   STATUS      RESTARTS   AGE
weka-kmod-drivers-build-1-build     0/1     Completed   0          11m
weka-kmod-drivers-container-pd7tx   1/1     Running     0          11m

```
Then you can test it with:
```commandline
oc -n weka-kmod-drivers exec -it $(oc get pods -n weka-kmod-drivers | grep container | awk '{print $1}') -- lsmod | head
# should include:
# wekafsio            35201024  0
# wekafsgw               32768  2 wekafsio
```

# For running the commands below you must have a running weka cluster

## set backend config map private ip and worker net:
Note: if the worker has only one nic, you must add new nic
```commandline
oc create configmap backend --from-literal=private_ip="$BACKEND_PRIVATE_IP" --from-literal=net="$WORKER_NET"
```

## add ecr permissions:
```commandline
openshift/add_ecr_secret.sh
```

## add weka client pod:
```commandline
oc apply -f performance_addon/qos-pod-weka.yaml
```

# Weka CSI plugin installation
```commandline
# First need to ssh into the openshift worker instance and set in /etc/selinux/config: "SELINUX=permissive"
oc create namespace csi-wekafs
oc adm policy add-scc-to-user privileged system:serviceaccount:csi-wekafs:csi-wekafs-node
oc adm policy add-scc-to-user privileged system:serviceaccount:csi-wekafs:csi-wekafs-controller
# https://artifacthub.io/packages/helm/csi-wekafs/csi-wekafs
helm repo add csi-wekafs https://weka.github.io/csi-wekafs
helm install csi-wekafs csi-wekafs/csi-wekafsplugin --namespace csi-wekafs --create-namespace
endpoints=$(echo -n "$BACKEND_PRIVATE_IP1:14000,$BACKEND_PRIVATE_IP2:14000" | base64)
sed -i "s/endpoints:.*/endpoints: $endpoints/g" weks-csi-plugin/test_pod.yaml
oc create -f weks-csi-plugin/test_pod.yaml
```

# Destroying cluster
## destroy openshift cluster:
Note: you have to make sure the resources that were created by openshift, are not in use by resources that are not
related to openshift. A common use case: there is an existing weka cluster that is using the openshift cluster subnet, 
so it must be destroyed before running the command below.
```commandline
AWS_PROFILE=AdminInsecure openshift-install destroy cluster --dir=cluster --log-level=debug
```
