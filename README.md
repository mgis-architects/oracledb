# oracledb

## What does it do
Configures Linux for Oracle

Install Oracle single instance 

On Grid Infrastructure Restart 

With Oracle ASM using udev persisted disks

## Pre-req
Staged binaries on Azure File storage in the following directories
* grid12102/V46096-01_1of2.zip
* grid12102/V46096-01_2of2.zip
* database12102/V46095-01_2of2.zip
* database12102/V46095-01_2of2.zip

### Step 1 Prepare oracledb build
git clone https://github.com/mgis-architects/oracledb

cp oracledb-build.ini ~/oracledb-build.ini

Modify ~/oracledb-build.ini

### Step 2 Execute the script using the Terradata repo
git clone https://github.com/mgis-architects/terraform

cd azure/oracledb

cp oracledb-azure.tfvars ~/oracledb-azure.tfvars

Modify ~/oracledb-azure.tfvars

terraform apply -var-file=~/oracledb-azure.tfvars

### Notes
Installation takes up to 35 minutes
