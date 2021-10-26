#!/bin/bash

vpcid=$(aws cloudformation describe-stacks --stack-name EKSGDB1 --query 'Stacks[].Outputs[?(OutputKey == `VPC`)][].{OutputValue:OutputValue}' --output text)

rm -f eksauroragdb.yaml

cat << EOF > eksauroragdb.yaml
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: eksgdbclu
  region: ${AWS_REGION}
  version: "1.21"
vpc:
  id: ${vpcid}
  subnets:
    private:
EOF

aws ec2 describe-subnets --filters Name=vpc-id,Values=${vpcid} --query 'Subnets[?(! MapPublicIpOnLaunch)].{AvailabilityZoneId:AvailabilityZoneId,SubnetId:SubnetId}' --output text | while read az subnet
do
 echo "       ${az}: { id: ${subnet} }" >> eksauroragdb.yaml
done

cat <<EOF >> eksauroragdb.yaml
managedNodeGroups:
  - name: eksgdb-1-workers
    minSize: 2
    maxSize: 3
    desiredCapacity: 2
    instanceType: t3.large
    labels: {role: worker}
    privateNetworking: true
    ssh:
      enableSsm: true
    tags:
      nodegroup-role: worker
    iam:
      withAddonPolicies:
        externalDNS: true
        certManager: true
        albIngress: true
secretsEncryption:
  keyARN: ${MASTER_ARN}
EOF

keyid=$AWS_ACCESS_KEY_ID
skey=$AWS_SECRET_ACCESS_KEY
defreg=$AWS_DEFAULT_REGION

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

eksctl create cluster -f eksauroragdb.yaml

STACK_NAME=$(eksctl get nodegroup --cluster eksgdbclu -o json | jq -r '.[].StackName')
ROLE_NAME=$(aws cloudformation describe-stack-resources --stack-name $STACK_NAME | jq -r '.StackResources[] | select(.ResourceType=="AWS::IAM::Role") | .PhysicalResourceId')
echo "export ROLE_NAME=${ROLE_NAME}" | tee -a ~/.bash_profile

c9builder=$(aws cloud9 describe-environment-memberships --environment-id=$C9_PID | jq -r '.memberships[].userArn')
if echo ${c9builder} | grep -q user; then
	rolearn=${c9builder}
        echo Role ARN: ${rolearn}
elif echo ${c9builder} | grep -q assumed-role; then
        assumedrolename=$(echo ${c9builder} | awk -F/ '{print $(NF-1)}')
        rolearn=$(aws iam get-role --role-name ${assumedrolename} --query Role.Arn --output text) 
        echo Role ARN: ${rolearn}
fi

eksctl create iamidentitymapping --cluster eksgdbclu --arn ${rolearn} --group system:masters --username admin

export AWS_ACCESS_KEY_ID=$keyid
export AWS_SECRET_ACCESS_KEY=$skey
export AWS_DEFAULT_REGION=$defreg
