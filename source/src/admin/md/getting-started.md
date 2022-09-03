## Getting Started


### Downloading Pre-built Binaries

The easiest way to get LiteStore is by downloading one of the prebuilt binaries from the [Github Release Page][release]:

  * [LiteStore for Mac OS X (x64)](https://github.com/h3rald/litestore/releases/download/{{$version}}/litestore_{{$version}}_macosx_x64.zip) 
  * [LiteStore for Windows (x64)](https://github.com/h3rald/litestore/releases/download/{{$version}}/litestore_{{$version}}_windows_x64.zip)
  * [LiteStore for Linux (x64)](https://github.com/h3rald/litestore/releases/download/{{$version}}/litestore_{{$version}}_linux_x64.zip)
  
### Running a Docker Image as a Container

Official Docker images are available [on Docker Hub](https://hub.docker.com/repository/docker/h3rald/litestore).

Just pull the latest version:

[docker pull h3rald/litestore:v{{$version}}](class:cmd)

then start a container to run the image on port 9500:

[docker run -p 9500:9500 h3rald/litestore:v{{$version}} -a:0.0.0.0](class:cmd)

> %tip%
> Tip
> 
> The [Dockerfile](https://github.com/h3rald/litestore/blob/master/Dockerfile) used to create tbe image is available in root of tbe LiteStore Github repository.

### Installing using Nimble

If you already have [Nim](http://nim-lang.org/) installed on your computer, you can simply run

[nimble install litestore](class:cmd)

### Running the Administration App

A simple but functional Administration App is available to manage LiteStore, create documents interactively, view and search content, etc. 

To get the app up and running (assuming that you have the [litestore](class:cmd) executable in your path):

1. Extract the default **data.db** file included in the LiteStore release package. This file is a LiteStore data store file containing the sample app.
2. Go to the local directory in which you downloaded the [data.db](class:cmd) file.
3. Run [litestore -s:data.db](class:cmd)
4. Go to [localhost:9500/docs/admin/index.html](http://localhost:9500/docs/admin/index.html).
