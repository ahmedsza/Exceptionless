# Exceptionless
Please refer to the official Exceptionless repo for details - https://github.com/exceptionless/Exceptionless

The purpose of this fork was to setup a POC environment to get Exceptionless running in AKS

# To get this working
In order to get this working, check out the ex-poc-setup.sh file. 

You will need to do this run these command first

rm -rf Exceptionless

git clone https://github.com/ahmedsza/Exceptionless.git 

cd Exceptionless/k8s

then run the ex-poc-setup.sh file