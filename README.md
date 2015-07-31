# cSphere 自动安装脚本
标准使用方法请参考https://csphere.cn/docs/1-installation.html

如果想基于本脚本安装，可参考下面的介绍。

**注意：** 

1. 要把AUTH_KEY换成你自己设定的足够安全的字符串，并保证controller与agent使用同一个key
2. 安装agent时要配置正确的controler的内网IP和controller的端口（默认为1016）


## 安装controller
```
ROLE=controller AUTH_KEY=helloworld CSPHERE_VERSION=0.12.4 make install

```

## 安装agent
```
ROLE=agent CONTROLLER_IP=$IP CONTROLLER_PORT=$PORT CSPHERE_VERSION=0.12.4 AUTH_KEY=helloworld make install
```

# 发布方法
先执行

```
make build
```

然后把生成的`install.sh`放到线上供用户使用。
