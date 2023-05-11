# Passwordless MySQL in AKS with Workload Identities --DRAFT--

Azure Database for MySQL has a really nice feature that allows you to use a Managed Identity to connect your Spring or Java application to your database, with minimal configuration changes and usually without any code change, just a few lines in your `pom.xml` file and a couple of lines in your `application.properties` file or in your `application.yml` file.

If you run your app in a Kubernetes cluster, you can use [Workload Identities][workload-identity] to connect to your database without having to store any credentials in your code or in your cluster.

## What will you need?

There are two parts in this exercise. First you need to setup the database to allow the connection with the Managed Identity, and then you need to setup the Kubernetes cluster to allow the connection from the application to the database.

For the database part, you will need to have a Managed Identity that will be used to configure the AAD authentication in the database. This MI is not the same as the one that will be used in the application, and it needs a special permission to be able to configure the database. The steps to provide these permissions are documented in this article: [Azure AD authentication for MySQL Flexible Server from end to end][aadauth-mysql], but don't worry, we will go through them in this article too.

For the Kubernetes part, you will need to have a Kubernetes cluster with the Workload Identity enabled. This is a feature that is still in preview, and you will need to enable it in your cluster. The steps to enable it are documented in this article: [Use managed identities in Azure Kubernetes Service][aks-wi].

So here's the bill of materials of what we will use in this example:
* General
    * An Azure subscription.
    * The Azure CLI.
    * Docker installed in your machine.
    * A Container Registry (ACR).
    * Java 17 and Maven installed in a machine to build the application (or you can run everything with docker, no need to install anything else).
* MySQL database:
    * A MySQL Flexible Server.
    * A Managed Identity, needed for setting up AAD authentication, with the following Graph permissions: User.Read.All, GroupMember.Read.All, Application.Read.All. Assigning these permissions is a bit tough because there's no way to add them from the UI and you need some arcane PowerShell commands to do it properly. The good news is that we have a script that will do it for you.
    * A user with Global Administrator permissions in the Azure AD tenant. You need it to set the permissions for the Managed Identity.
    * A MySQL client, like MySQL Workbench or the `mysql` cli, to connect to the database and run some queries.
* Kubernetes cluster:
    * An AKS cluster, we can create it or use an existing one that we will upgrade to enable Workload Identities.
    * Another Managed Identity, this one will be used by the application to connect to the database.
    * The `kubectl` CLI to connect to the cluster and deploy the application.

## Building the application

Start with the variables:

```bash
export GIT_REPO="https://github.com/jmservera/airsonic-advanced.git"
export GIT_BRANCH=azure_passwordless

export ACR_NAME=<Your Azure Container Registry> # The ACR needs to exist
```

```bash
git clone $GIT_REPO -b $GIT_BRANCH
```

For this example, I'm going to use an existing application that I configured to use the passwordless approach. The application is a fork of the [Airsonic Advanced][airsonic] project, a music streaming server. I chose this project because it's a Java application that uses a MySQL database, and it's a bit more complex than a simple "Hello World" application.

As I said before, there will be no code changes, but we I had to update the application to add support for passwordless MySQL. This application uses Spring Boot, so I added the Spring Cloud Azure JDBC dependency to the [`pom.xml`][pomxml] file:

```xml
<dependency>
    <groupId>com.azure.spring</groupId>
    <artifactId>spring-cloud-azure-starter-jdbc-mysql</artifactId>
    <version>5.1.0</version>
</dependency>
```

The project comes with an already prepared Dockerfile, but I also had to update to a newer version of the OpenJDK image to use Java 17 because adoptopenjdk is not providing images for Java 17 anymore. I chose to use the [Eclipse Temurin][temurin] images, which are the official images for OpenJDK.

```dockerfile
FROM eclipse-temurin:17.0.7_7-jdk AS builder

[...]

FROM eclipse-temurin:17.0.7_7-jre

[...]
```

Once everything prepared and with the [Java 17 JDK][openjdk] installed, I ran this command to build the application:

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

> Some explanation about this command: the `-v $(pwd):/src:rw` provides read write access to the folder where you are running the command, this should be the source code folder that you downloaded from GitHub, `-v /tmp/profile:/root:rw` is used to cache the downloaded references in case you need to run it again, and the modifier `-v /var/run/docker.sock:/var/run/docker.sock` provides access to the your local docker. 

This will build the application and create a docker image with the application. The image needs to be retagged with the name of the ACR to push it to your Azure Container Registry:

```bash
docker tag airsonicadvanced/airsonic-advanced:latest \
    $(ACR_NAME).azurecr.io/airsonic-advanced:0.4
docker push -a $(ACR_NAME).azurecr.io/airsonic-advanced
```

## Kubernetes deployment files

* PVC
* Deployment
* Service

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

You probably did a small mistake when setting up the identity. This is a very generic message that can happen due multiple reasons, in my case I had two issues: a typo and a wrong reference.

#### Remember case-sensitivity

First, the identity was created with a capital `I`  in `myIdentity`, but then I
created the service account and the user with a lowercase letter like
`myidentity`. So nobody knew who was the right user.

#### Are you referencing the right library?

Another big mistake was that I used the wrong library. I was using a Spring Boot
application, but as per the previous mistake, my solution was not working, I
moved back to use a plain Java library instead of the Spring one.

```xml
<dependency>
    <groupId>com.azure</groupId>
    <artifactId>azure-identity-extensions</artifactId>
    <version>1.0.0</version>
</dependency>
```

But as it’s using Spring boot it should be this other one:

```xml
<dependency>
    <groupId>com.azure.spring</groupId>
    <artifactId>spring-cloud-azure-starter-jdbc-mysql</artifactId>
    <version>5.1.0</version>
</dependency>
```

## References

* https://learn.microsoft.com/en-us/azure/developer/java/spring-framework/migrate-mysql-to-passwordless-connection?tabs=sign-in-azure-cli%2Cspring%2Caks
* https://techcommunity.microsoft.com/t5/azure-database-for-mysql-blog/azure-ad-authentication-for-mysql-flexible-server-from-end-to/ba-p/3696353
* https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview
* intro: https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/overview

[aadauth-mysql]: https://techcommunity.microsoft.com/t5/azure-database-for-mysql-blog/azure-ad-authentication-for-mysql-flexible-server-from-end-to/ba-p/3696353
[airsonic]: https://github.com/jmservera/airsonic-advanced/tree/azure_passwordless
[aks-wi]: https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview
[openjdk]: https://jdk.java.net/archive/
[pomxml]: https://github.com/jmservera/airsonic-advanced/blob/azure_passwordless/airsonic-main/pom.xml
[temurin]: https://hub.docker.com/_/eclipse-temurin
[workload-identity]: https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview
