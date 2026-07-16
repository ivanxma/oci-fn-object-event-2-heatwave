# Object Storage → HeatWave OCI Function

This package deploys a Python 3.13 OCI Function into `HWDemo`, with a private subnet selected from `vcn_ivanma_london`. An Events rule forwards Object Storage create, delete, and update events to the function. The function creates `fndb.object_event` if it does not already exist, then writes each received event's timestamp, type, full JSON message, and extracted `bucket_name`, `compartment_name`, `resource_name`, `namespace`, and `event_time` columns. The host bootstrap uses the Oracle Linux `python3` package only for tooling; Python 3.13 is supplied by the function container image.

## One-time prerequisites

The OCI Compute instance principal must be permitted to inspect VCNs/subnets and manage Functions/Events in `HWDemo`. The deploying OCI user also needs an OCIR auth token and permission to push to the selected repository. The function subnet's security lists/NSGs and routing must permit egress to the configured HeatWave endpoint.

The deployment creates the private `hw-demo-functions/object-storage-heatwave` OCIR repository explicitly in `HWDemo`, so the instance dynamic group also needs `manage repos in compartment HWDemo`. If a prior deployment auto-created that repository in the tenancy root compartment, move it to `HWDemo` before retrying; do not leave duplicate repositories.

If granting VCN read access is not possible, obtain the target private subnet OCID and export it as `SUBNET_ID`. The deployment script will then skip VCN/subnet discovery.

## Deploy

```sh
cd ~/oci-fn
./bootstrap.sh
cp env.sh.example env.sh
chmod 600 env.sh
# Edit env.sh locally with DB and OCIR deployment values.
./deploy.sh
```

`env.sh` is git-ignored and must never be committed. `OBJECT_STORAGE_COMPARTMENT_ID`
must be the `HWDemo` compartment OCID (and may be omitted because the script
defaults it to `HWDemo`). The Events rule itself is always created in `HWDemo`;
the script refuses a cross-compartment source.

`deploy.sh` writes `function-report.html`. Open it locally or copy it off the host; it contains resource identifiers and no secrets.

## Test

Create, overwrite, then delete a small object in an Object Storage bucket in `OBJECT_STORAGE_COMPARTMENT_ID`. Inspect function invocations in OCI Console Metrics/Logs, or invoke it directly after deployment:

```sh
echo '{"eventType":"com.oraclecloud.objectstorage.createobject","data":{"additionalDetails":{"bucketName":"test","objectName":"test.txt"}}}' | fn invoke object-storage-heatwave-app object-storage-heatwave
```

The expected response has `"status":"accepted"` and `"database":"event stored"`. The configured DB user needs `CREATE` and `INSERT` privileges on `fndb`.
