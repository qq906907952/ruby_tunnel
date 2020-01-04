端口转发工具
======
ruby实现使用ssl协议实现本地和远程端口转发（类似ssh端口转发）

使用方法
======
本地修改client.json配置文件：
-------
    {
      "client": [                             //数组 可以配置多个
        {
          "server_addr": "127.0.0.1",         //远程服务器地址
          "server_port": 999,                 //远程服务器端口
          "redir_mode": "remote_local",       //转发模式 remote_local表示服务器监听端口，转发到本地
          "listen_port": 1919,                //服务器转发监听端口
          "redir_addr":"127.0.0.1",           //转发的ip
          "redir_port":19191,                 //转发的端口
          "cert": {                           //证书
            "serv_name": "ydx.com",           
            "serv_root_cert": "cert/serv/root.crt",   //服务器根证书
            "private_key": "cert/client/client.key",  //客户端私钥
            "cert_chain": [                           //客户端证书链
              "cert/client/client.crt"
            ]
          }
        },
    
        {
          "server_addr": "127.0.0.1",
          "server_port": 999,
          "redir_mode": "local_remote",       //转发模式 local_remote表示监听本地端口，转发到服务器
          "listen_port": 1919,                //本地监听端口
          "redir_addr":"127.0.0.1",
          "redir_port":19191,
          "cert": {
            "serv_name": "ydx.com",
            "serv_root_cert": "cert/serv/root.crt",   
            "private_key": "cert/client/client.key",  
            "cert_chain": [                           
              "cert/client/client.crt"
            ]
          }
        }
      ]
    }
    
    执行   ruby main.rb -c client.json
    
服务端修改server.json
-------

       {
         "server": [                    //数组
           {
             "listen_port": 999,        //服务端监听端口
             "cert": {                  //证书
               "private_key": "cert/serv/server.key",     //服务器私钥
               "cert_chain": [                            //服务端证书链
                 "cert/serv/server.crt",
                 "cert/serv/root.crt"
               ],
               "cient_certs": [                          //客户端证书
                 "cert/client/client.crt"
               ]
             }
           }
         ]
       
       }
       
    执行   ruby main.rb -c server.json
    
关于证书
-------
本地与服务器使用ssl双向校验，因此需要生成服务端与客户端的私钥与自签证书。

服务端需要自身证书与私钥，并添加客户端的证书作为校验

客户端需要自身证书与私钥，并添加服务端的根证书信任

cert目录下包含生成证书的脚本。

切到cert/serv目录下修改cert/serv/serv.cnf 中 alt_names.IP.1 改为服务器ip 或者 alt_names.NDS.1改为服务器域名，

执行 bash create_serv_crt.sh 生成证书与私钥，其中root.crt是根证书，server.crt 和 server.key 是服务器证书与私钥，默认是两级证书链

切到cert/client目录下 执行 bash create_cli_crt.sh 生成单个客户端证书与私钥，默认只有一级证书链

bash create_cli_crt.sh ${n}  批量生成 ${n}为整数