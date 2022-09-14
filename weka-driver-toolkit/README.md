# Installation:

## Create build container
```
oc create -f 0000-weka-kvc-buildconfig-driver-container-namespace.yaml
```

## Test 1
```
oc get pod -n weka-kmod-drivers

# NAME                                READY   STATUS    RESTARTS   AGE
# weka-kmod-drivers-container-59hjs   1/1     Running   0          26h
# weka-kmod-drivers-container-5mg9m   1/1     Running   0          26h
# weka-kmod-drivers-container-g6td6   1/1     Running   0          26h
# weka-kmod-drivers-container-tsv5f   1/1     Running   2          26h
```
## Test 2
```
oc -n weka-kmod-drivers exec -it pod/weka-kmod-drivers-container-tsv5f -- lsmod | head

# Module                  Size  Used by
# wekafsio             5193728  0
# wekafsgw               32768  2 wekafsio
# igb_uio                16384  0
# uio_pci_generic        16384  0
# veth                   28672  0
```




# Deletion:
```
oc delete -f 0000-weka-kvc-buildconfig-driver-container-namespace.yaml
```
