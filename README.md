# aws-online-snap-store-proxy
Setup snap-proxy and client in AWS

Configure your variables in config.sh and then run:

To create the required resources on AWS:

```
./create_resources.sh
```

To setup snap-proxy (after resources have been created):

```
./setup_snap_proxy.sh
```

To setup a sample client (after snap-proxy is set up):

```
./setup_snap_client.sh
``` 

To Cleanup all resources:

```
./cleanup_resources.sh
```
