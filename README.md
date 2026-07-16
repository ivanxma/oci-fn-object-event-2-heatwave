# Object Storage → HeatWave OCI Function

This package deploys a Python 3.13 OCI Function into the compartment and private subnet selected in `env.sh`. An Events rule forwards Object Storage create, delete, and update events to the function. The function creates `fndb.object_event` if it does not already exist, then writes each received event's timestamp, type, full JSON message, and extracted `bucket_name`, `compartment_name`, `resource_name`, `namespace`, and `event_time` columns. The host bootstrap uses the Oracle Linux `python3` package only for tooling; Python 3.13 is supplied by the function container image.

## One-time prerequisites

Set `COMPARTMENT_ID` to the target deployment compartment. The Object Storage bucket, Function application, OCIR repository, and Events rule must be in that same compartment. The OCI Compute instance principal must be permitted to inspect VCNs/subnets and manage Functions/Events there. The deploying OCI user also needs an OCIR auth token and permission to push to the selected repository. The function subnet's security lists/NSGs and routing must permit egress to the configured HeatWave endpoint.

The deployment creates the private `${REPOSITORY_PREFIX}/${FUNCTION_NAME}` OCIR repository explicitly in `COMPARTMENT_ID`, so the instance dynamic group also needs repository-management permission in that compartment. If a prior deployment auto-created that repository in the tenancy root compartment, move it to the target compartment before retrying; do not leave duplicate repositories.

If granting VCN read access is not possible, obtain the target private subnet OCID and export it as `SUBNET_ID`. The deployment script will then skip VCN/subnet discovery.

## IAM dynamic group and policies

The deployment scripts use the OCI Compute instance principal. Create a dynamic
group that includes the Compute instance, replacing the placeholder with the
compartment containing that instance:

```text
ALL { resource.type = 'instance', resource.compartment.id = '<compute-compartment-ocid>' }
```

An IAM administrator must create the following policies. Replace
`<dynamic-group-name>` and `<deployment-compartment-name>`; every statement is
scoped to the selected deployment compartment.

```text
Allow service faas to read repos in compartment <deployment-compartment-name>
Allow dynamic-group <dynamic-group-name> to use virtual-network-family in compartment <deployment-compartment-name>
Allow dynamic-group <dynamic-group-name> to manage functions-family in compartment <deployment-compartment-name>
Allow dynamic-group <dynamic-group-name> to manage cloudevents-rules in compartment <deployment-compartment-name>
Allow dynamic-group <dynamic-group-name> to manage repos in compartment <deployment-compartment-name>
Allow dynamic-group <dynamic-group-name> to read objectstorage-namespaces in compartment <deployment-compartment-name>
```

For `showlog.sh`, add these read-only logging permissions. The second statement
is needed only to discover Log Group and Log OCIDs through the CLI; the script
itself needs `read log-content` after those OCIDs are in `env.sh`.

```text
Allow dynamic-group <dynamic-group-name> to read log-content in compartment <deployment-compartment-name>
Allow dynamic-group <dynamic-group-name> to inspect log-groups in compartment <deployment-compartment-name>
```

IAM policy creation might require tenancy or parent-compartment permissions. An
administrator can create the policy at the appropriate ancestor while retaining
the compartment-only scope shown above.

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
must equal `COMPARTMENT_ID` (and may be omitted because the script defaults it
to `COMPARTMENT_ID`). The Events rule is created in that same compartment; the
script refuses a cross-compartment source.

`deploy.sh` writes `function-report.html`. Open it locally or copy it off the host; it contains resource identifiers and no secrets.

## Show recent function logs

Enable **Function Invocation Logs** for the application first. Then, from the
deployment host, show the last 15 minutes of logs (or supply a different number
of minutes and an optional result limit):

```sh
./showlog.sh 15
./showlog.sh 60 250
```

The script searches only the configured application and function in the
`COMPARTMENT_ID` from `env.sh`. Set `FUNCTION_LOG_GROUP_ID` and
`FUNCTION_LOG_ID` from the enabled Function Invocation Log's details page in
the same compartment. It uses the instance principal by default; set `OCI_AUTH`
only when another OCI CLI authentication method is required.

## Test

Create, overwrite, then delete a small object in an Object Storage bucket in `OBJECT_STORAGE_COMPARTMENT_ID`. Inspect function invocations in OCI Console Metrics/Logs, or invoke it directly after deployment:

```sh
echo '{"eventType":"com.oraclecloud.objectstorage.createobject","data":{"additionalDetails":{"bucketName":"test","objectName":"test.txt"}}}' | fn invoke object-storage-heatwave-app object-storage-heatwave
```

The expected response has `"status":"accepted"` and `"database":"event stored"`. The configured DB user needs `CREATE` and `INSERT` privileges on `fndb`.
