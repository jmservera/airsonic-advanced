# Connect Passwordless to MySQL from AKS with Workload Identities --DRAFT--

In this guide we will go through the steps to connect an application running in
an AKS cluster to a MySQL database without having to store any credentials in
the application or in the cluster. We will use the passwordless approach, which
uses Azure Active Directory (AAD) authentication to connect to the database.

<!--- more --->

With Azure Database for MySQL you can use a Managed Identity to connect your
Spring or Java application to your database using a
[passwordless connection][passwordless-mysql]. You can achieve this with minimal
configuration changes and usually without any code change, just a few lines in
your `pom.xml` file to add a reference and a couple of lines in your
`application.properties` file or in your `application.yml` file to setup the
connection.

On the other hand, when you run your app in an Azure Kubernetes Service cluster,
you can use the [Workload Identities][workload-identity] to connect to other
resources from a workload, without having to store any credentials in your code
or in your cluster. This feature uses a Managed Identity, but instead of
attaching this MI to a cluster or to the VM, now it is associated to a
[Kubernetes Service Account][service-account], using a native k8s feature to
provide the credentials to the application using [identity federation][oidc].

Let's use this two features to connect our application to our database without
having to store any credentials in our code or in our cluster.

## Summary

There are two parts in this exercise: setup the database to allow the connection
with the Managed Identity, and configure the Kubernetes cluster to allow the
connection from the application to the database.

For the database, you will need to have a Managed Identity that will be
used to configure the AAD authentication in the database. This MI is not the
same as the one that will be used in the application, and it needs a special
permission to be able to configure the database. The steps to provide these
permissions are documented in this article:
[Azure AD authentication for MySQL Flexible Server from end to end][aadauth-mysql],
but don't worry, we will go through them in this article too, and using the new
*Microsoft.MgGraph* PowerShell module.

Then you need to have an AKS cluster with the Workload Identity enabled.
This is a feature that is still in preview, and you will need to enable it in
your cluster. The steps to enable it are documented in this article:
[Use managed identities in Azure Kubernetes Service][aks-wi].

So here's the bill of materials of what we will use in this example:

* Basics:
  * An Azure subscription.
  * A user with Global Administrator permissions in the Azure AD tenant.
  * Docker installed in your machine.
  * A Linux distribution with Bash, Kubectl and Powershell installed, you can
    use the Windows Subsystem for Linux (WSL) if you are using Windows.

## Transforming a Spring Boot Application to use passwordless MySQL

In this article we will follow the steps to transform an existing instance of
MySQL and an existing AKS cluster. If you want to follow this exercise yourself,
I also provide some templates to create this initial state. You may find that
the initial templates are rather simple, but keep in mind that these are only
some basic boilerplate templates to use them as a starting point.

In this example we will use a Spring Boot application that uses a MySQL
database. The application is a fork of the [Airsonic Advanced][airsonic]
project, a music streaming server with a long story, and I find it useful for
this exercise because you can edit and see the database connection in their own
UI:

![Airsonic app with no password in the JDBC config][airsonic_no_pwd]

In the `install/k8s` folder of my [airsonic fork][airsonic] you will find all
the scripts and templates to build and deploy the application to an AKS cluster.
I also included all the steps to install powershell in Linux, and the needed
extensions for the `az` cli and the PowerShell modules. You can clone the
repository and checkout the branch `azure_passwordless` to get the code for this
example:

```bash
git clone "https://github.com/jmservera/airsonic-advanced.git" -b azure_passwordless
```

Go to the `install/k8s` folder and copy the `.env-demo` file to `.env`:

```bash
cd install/k8s
cp .env-demo .env
```

Now edit the `.env` file and set your own values, do it at least for these variables:

```bash
APP_NAME="airsonic"

# basic resources
SUBSCRIPTION_ID="" # The subscription ID, if you leave this blank,
                   # you will be prompted to select a subscription
ACR_NAME="Your Azure Container Registry name"
AKS_CLUSTER="your AKS cluster name"
RESOURCE_GROUP="your resource group name"
LOCATION="westeurope" # Will only be used if you create a new resource group
```

> **TL;DR:** If you want to skip the explanation and go directly to the code,
you can run the `install/k8s/install.sh` script. I tried to made it idempotent,
so you can try different things and run it again if anything failed because of
the credentials. You only need to run it from *bash* and it will take care of
installing everything you need to run the scripts.
If you already have the basic resources created (ACR, AKS and MySQL) you can
skip the creation by adding the *-d* flag to the `install.sh` script. Otherwise,
the script will create them for you.

### Building the application

As I said before, there will be no code changes, but we must update the
application references and configuration to add support for passwordless MySQL.
This application uses Spring Boot, so I added the Spring Cloud Azure JDBC
dependency to the [`pom.xml`][pomxml] file:

```xml
<dependency>
    <groupId>com.azure.spring</groupId>
    <artifactId>spring-cloud-azure-starter-jdbc-mysql</artifactId>
    <version>5.1.0</version>
</dependency>
```

The project comes with an already prepared Dockerfile, but I also had to update
to a newer version of the OpenJDK image to use Java 17 because adoptopenjdk is
not providing images for Java 17 anymore. I chose to use the
[Eclipse Temurin][temurin] images, which are the official images for OpenJDK.

```dockerfile
FROM eclipse-temurin:17.0.7_7-jdk AS builder

[...]

FROM eclipse-temurin:17.0.7_7-jre

[...]
```

Once everything prepared and with the [Java 17 JDK][openjdk] installed, I ran
this command to build the application:

```bash
mvn clean package -DskipTests -P docker
```

You can also use docker to build the application:

```bash
docker run -it --rm --workdir /src \
  -v $(pwd):/src:rw \
  -v /tmp/profile:/root:rw \
  -v /var/run/docker.sock:/var/run/docker.sock \
  maven:3.9.1-eclipse-temurin-17 \
  mvn clean package -DskipTests -P docker
```

> Some explanation about this command: the `-v $(pwd):/src:rw` provides read
write access to the folder where you are running the command, this should be the
source code folder that you downloaded from GitHub, `-v /tmp/profile:/root:rw`
is used to cache the downloaded references in case you need to run it again, and
the modifier `-v /var/run/docker.sock:/var/run/docker.sock` provides access to
the your local docker.

This will build the application and create a docker image with the application.
The image needs to be retagged with the name of the ACR to push it to your Azure
Container Registry:

```bash
docker tag airsonicadvanced/airsonic-advanced:latest \
    ${ACR_NAME}.azurecr.io/airsonic-advanced:${VERSION}
docker push -a ${ACR_NAME}.azurecr.io/airsonic-advanced
```

## Prepare the database

* Setup firewall
* Connect with token
* Create AD User

## Prepare the Kubernetes cluster

* Update for workload identity
* Create the service account

## Deploy the application

* Create the service account for the Workload Identity.
* Modify the deployment to use the service account and move to passwordless.

* PVC
* Deployment
* Service

## Common errors

A list of the mistakes I did and the errors that were showing:

### Environment not set

Sometimes you get an error from the DefaultCredentials that says something about
the environment variables not being set. In my case, this happened because the
scripts were adding an extra `\n` character to many of the strings, including
username or user id, creating a lot of invisible mess.

### Access denied for user

If you are seeing something like this in your logs:

```log
2023-05-10 14:49:41.153  INFO --- org.airsonic.player.Application          : Starting Application using Java 17.0.7 on airsonic-sts-0 with PID 1 (/app/WEB-INF/classes started by root in /var)
2023-05-10 14:49:41.156  INFO --- org.airsonic.player.Application          : No active profile set, falling back to 1 default profile: "default"
2023-05-10 14:49:45.744 ERROR --- a.i.e.j.m.AzureMysqlAuthenticationPlugin : Cannot invoke "String.getBytes(String)" because "password" is null
Cannot invoke "String.getBytes(String)" because "password" is null
2023-05-10 14:49:46.828 ERROR --- c.zaxxer.hikari.pool.HikariPool          : HikariPool-1 - Exception during pool initialization.
 
java.sql.SQLException: Access denied for user 'myIdentity'@'52.151.238.80' (using password: NO)
        at com.mysql.cj.jdbc.exceptions.SQLError.createSQLException(SQLError.java:129) ~[mysql-connector-java-8.0.30.jar:8.0.30]
        at com.mysql.cj.jdbc.exceptions.SQLExceptionsMapping.translateException(SQLExceptionsMapping.java:122) ~[mysql-connector-java-8.0.30.jar:8.0.30]
        at com.mysql.cj.jdbc.ConnectionImpl.createNewIO(ConnectionImpl.java:828) ~[mysql-connector-java-8.0.30.jar:8.0.30]
        at com.mysql.cj.jdbc.ConnectionImpl.<init>(ConnectionImpl.java:448) ~[mysql-connector-java-8.0.30.jar:8.0.30]
        at com.mysql.cj.jdbc.ConnectionImpl.getInstance(ConnectionImpl.java:241) ~[mysql-connector-java-8.0.30.jar:8.0.30]
        at com.mysql.cj.jdbc.NonRegisteringDriver.connect(NonRegisteringDriver.java:198) ~[mysql-connector-java-8.0.30.jar:8.0.30]
        at com.zaxxer.hikari.util.DriverDataSource.getConnection(DriverDataSource.java:138) ~[HikariCP-4.0.3.jar:na]
        at com.zaxxer.hikari.pool.PoolBase.newConnection(PoolBase.java:364) ~[HikariCP-4.0.3.jar:na]
```

You probably did a small mistake when setting up the identity. This is a very
generic message that can happen due multiple reasons, in my case I identified
three different issues: a typo in the identity name, a wrong library reference
and a wrong namespace. These three mistakes cause the same error message so it's
not easy to identify the root cause.

#### Remember case-sensitivity

First, the identity was created with a capital `I`  in `myIdentity`, but then I
created the service account and the user with a lowercase letter like
`myidentity`. So nobody knew who was the right user.

#### Are you referencing the right library?

Another big mistake was that I used the wrong library. I was using a Spring Boot
application, but as per the previous mistake, my solution was not working, I
moved back to try to use a plain Java library instead of the Spring one.

```xml
<dependency>
    <groupId>com.azure</groupId>
    <artifactId>azure-identity-extensions</artifactId>
    <version>1.0.0</version>
</dependency>
```

But as it’s using Spring boot it should be this other one, that takes care of
all the magic that gets the token from the identity and injects it into the
connection string:

```xml
<dependency>
    <groupId>com.azure.spring</groupId>
    <artifactId>spring-cloud-azure-starter-jdbc-mysql</artifactId>
    <version>5.1.0</version>
</dependency>
```

#### Check the namespace twice

The last mistake was that I was using the wrong namespace. I was creating too
many things manually and I was creating the deployment in the application
namespace, called `airsonic`, but the federated identity was created in the
`default` namespace. It is an important setting that is in the `subject`that
you pass to the `az identity federated-credential create` command.

```bash
az identity federated-credential create --name ${FEDERATED_IDENTITY_CREDENTIAL_NAME} --identity-name ${WORKLOAD_IDENTITY_NAME} --resource-group ${RESOURCE_GROUP} --issuer ${AKS_OIDC_ISSUER} --subject system:serviceaccount:${KUBERNETES_NAMESPACE}:${SERVICE_ACCOUNT_NAME}
```

## BOM summary

* General
  * An Azure subscription.
  * The Azure CLI.
  * Bash and PowerShell installed in a Linux machine, or the Windows Subsystem
  for Linux (WSL).
  * Docker installed in your machine.
  * A Container Registry (ACR).
  * Java 17 and Maven installed in a machine to build the application (or you
  can run everything with docker, no need to install anything else).
* MySQL database:
  * A MySQL Flexible Server.
  * A Managed Identity, needed for setting up AAD authentication, with the
  following Graph permissions: User.Read.All, GroupMember.Read.All,
  Application.Read.All. Assigning these permissions is a bit tough because
  there's no way to add them from the UI and you need some arcane PowerShell
  commands to do it properly. The good news is that we have a script that will
  do it for you.
  * A user with Global Administrator permissions in the Azure AD tenant. You
  need it to set the permissions for the Managed Identity used to configure the
  AAD authentication in the database.
  * A MySQL client, like MySQL Workbench or the `mysql` cli, to connect to the
  database and run some queries.
* Kubernetes cluster:
  * An AKS cluster, we can create it or use an existing one that we will upgrade
  to enable Workload Identities.
  * Another Managed Identity, this one will be used by the application to
  connect to the database.
  * The `kubectl` CLI to connect to the cluster and deploy the application.

## References

* [Migrate MySQL to passwordless connection][passwordless-mysql]
* [Azure AD authentication for MySql Flexible Server][aadauth-mysql]
* [AKS Workload Identity Overview][aks-wi]
* [Managed Identities introduction][managed-identities]

[aadauth-mysql]: https://techcommunity.microsoft.com/t5/azure-database-for-mysql-blog/azure-ad-authentication-for-mysql-flexible-server-from-end-to/ba-p/3696353
[airsonic]: https://github.com/jmservera/airsonic-advanced/tree/azure_passwordless
[aks-wi]: https://learn.microsoft.com/azure/aks/workload-identity-overview
[managed-identities]: https://learn.microsoft.com/azure/active-directory/managed-identities-azure-resources/overview
[oidc]:https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-issuer-discovery
[openjdk]: https://jdk.java.net/archive/
[passwordless-mysql]: https://learn.microsoft.com/azure/developer/java/spring-framework/migrate-mysql-to-passwordless-connection
[pomxml]: https://github.com/jmservera/airsonic-advanced/blob/azure_passwordless/airsonic-main/pom.xml
[service-account]: https://kubernetes.io/docs/concepts/security/service-accounts/
[temurin]: https://hub.docker.com/_/eclipse-temurin
[workload-identity]: https://learn.microsoft.com/azure/aks/workload-identity-overview

[airsonic_no_pwd]: ./img/look_ma_no_passwords.png "Look Ma! No passwords!"
