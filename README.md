**Rime(小狼毫 )自用配置**

**词库：**
  * 主词库来自：[myshiqiqi/rime-wubi](https://github.com/myshiqiqi/rime-wubi)；
  * wubi86_user.dict.yaml：为自定义词库。
    
**使用说明：**

  - 下载仓库中所有文件放入用户文件夹

**文件说明：**
  
  * installation.yaml: 同步数据设定文件，需要网盘配合实现多设备同步；    
    同步目录: sync_dir:'D:\XXX\XXX'；    
    多设备命名: installation_id: "XXX"。
  * rime.lua: 输出日期时间脚本，脚本文件来自 [networm/Rime](https://github.com/networm/Rime)。    
      输入对应词，获取当前日期和时间       
         date 输出日期，格式: 2019年06月19日 2019-06-19    
         time 输出时间，格式: 10:00 10:000    
         week 输出星期，格式: 周四 星期四    
         month 输出月份，格式: August Aug    
