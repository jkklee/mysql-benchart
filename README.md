本文是作者工作中需要对[atlas](https://github.com/Qihoo360/Atlas)（360开源的mysql中间件，可实现读写分离、分表、多从库负载均衡）以及后期对[proxysql](https://github.com/sysown/proxysql/)（另一款高效并很有特色的数据库代理软件）进行测试时所设计和采用的一套脚本。由于对中间件测试，要测试对比的维度较多,所以尽量将涉及到的因素都纳入脚本中以实现自动化的压测和分析过程。总体思路如下：
```
graph TD
A(准备测试数据) -->|这步在脚本之外人工完成|B(运行脚本测试)
B -->|压测线程数在脚本里定义,压测次数也在脚本里默认为3|C(脚本将测试输出格式化后写入数据库)
C -->|脚本加 analyse 参数|D(将压测分析结果打印到标准输出)
C-->|脚本加 chart 参数|E(对压测结果中的所有测试场景进行绘图)
C-->|脚本加 chart '测试场景'...|F(只对给定额'测试场景进行绘图')
```

**脚本依赖于`sysbench-0.5`和`gnuplot`**

下面来看下脚本使用说明及用例截图

帮助信息：  
![image](http://s1.51cto.com/wyfs02/M00/88/EC/wKioL1gA9_vBi8sVAAUi_ih9Afw578.png)

进行测试：    
![image](http://s4.51cto.com/wyfs02/M00/7C/CC/wKiom1bYAeOA1GxwAAKll2FSJjs327.png)

查看分析结果：    
![image](http://s2.51cto.com/wyfs02/M00/88/EC/wKioL1gA_FWQYlLhAAxXSIWw6KQ525.png)

对结果进行画图：    
![image](http://s5.51cto.com/wyfs02/M00/88/F0/wKiom1gA-i_DtcQhAAB_1VY5wcQ438.png)

效果图展示：    
![image](http://s2.51cto.com/wyfs02/M02/88/EC/wKioL1gA-33y64FqAAAfUIYcEh0352.png)

接下来我们来了解一下sysbench-0.5对MySQL进行测试的方法及原理

sysbench-0.5，对于数据库的测试较0.4版本有较大不同，之前有内建的--test=oltp方法，现在改成了外部的lua脚本形式，这样更灵活，也方便用户构建自己的测试模型。

这些相关的lua脚本位于”/usr/share/doc/sysbench/tests/db/“ 目录，其内脚本如下图所示  
![image](http://s2.51cto.com/wyfs02/M01/7C/BD/wKiom1bW8M-yS4DpAAAoCWAEXJI478.png)

我们需要了解我们最有可能用到的三个脚本：common.lua（公共脚本）、oltp.lua（oltp测试主脚本）和parallel_prepare.lua（并行准备数据）。common.lua中定义了一些选项的默认值（故而，这些选项的值既可以通过命令行指定也可直接修改该脚本里对应值来更改）.

简单说一下oltp.lua脚本的逻辑:
```
默认通过显式的使用begin和commit语句将如下模式的sql组合在一起形成一个事务（只读测试的话则没有写请求）

关于oltp '读写'和'只读'测试的语句及其出现比例如下

10条    SELECT c FROM sbtest6 WHERE id=5047;
1条    SELECT c FROM sbtest16 WHERE id BETWEEN 5050 AND 5050+99;
1条    SELECT SUM(K) FROM sbtest7 WHERE id BETWEEN 5039 AND 5039+99;
1条    SELECT c FROM sbtest7 WHERE id BETWEEN 4987 AND 4987+99 ORDER BY c;
1条    SELECT DISTINCT c FROM sbtest7 WHERE id BETWEEN 13 AND 13+99 ORDER BY c;
1条    UPDATE sbtest1 SET k=k+1 WHERE id=1234;
1条    UPDATE sbtest2 SET c='78864443858-59732318638' where id=2345;
1条    DELETE FROM sbtest11 WHERE id=4958;
1条    INSERT 语句;

然后将此事务循环执行10000次。也就是只读测试共14w请求，混合测试18w请求。
若觉得数量不够，可以修改common.lua中的设置

function set_vars()
   oltp_table_size = oltp_table_size or 10000
   oltp_range_size = oltp_range_size or 100
   oltp_tables_count = oltp_tables_count or 1
   oltp_point_selects = oltp_point_selects or 20 （原来10）
   oltp_simple_ranges = oltp_simple_ranges or 2 （原来1）
   oltp_sum_ranges = oltp_sum_ranges or 2 （原来1）
   oltp_order_ranges = oltp_order_ranges or 2 （原来1）
   oltp_distinct_ranges = oltp_distinct_ranges or 2 （原来1）
   oltp_index_updates = oltp_index_updates or 1

   oltp_non_index_updates = oltp_non_index_updates or 1

这样总的测试请求量会变成28w
```
以上是通过lua脚本里总结出来的，各位也可查看下这些lua脚本，来更好的理解测试的逻辑过程。

一般来说，对MySQL做压测会基于两种需求：

- 一种是通过压测来大致评估MySQL实例的最大能力，这种适合给定时长来测；
- 另一种就是来对比某些改动前后的性能变化（如版本升级、参数调整等），这种适合给定请求数来测。

以作者的小经验来看，后者要更多一些，所以我的测试模式也是趋向于后者的。

前提功课做好了，接下来一起看一下本例的测试过程

**准备数据：**

在被测的mysql上执行如下命令（以8线程并发创建16张50w数据的表）
```
sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua \
         --mysql-table-engine=innodb --oltp-table-size=500000 --mysql-user=user \
         --mysql-password='passwd' --mysql-port=3306 --mysql-host=192.168.1.33 \
         --oltp-tables-count=16 --num-threads=8 run
```
还有另外一种方式，用oltp.lua脚本以串行方式准备数据
```
sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua --mysql-table-engine=innodb \
         --oltp-table-size=500000 --mysql-user=user --mysql-password='passwd' \
         --mysql-port=3306 --mysql-host=192.168.1.33 --oltp-tables-count=16 prepare
```

**开始测试：**
```
sh mysql_oltp_test.sh test atlas-24-threads read-only 192.168.1.44 3306 user passwd
```

**清空测试数据：**
```
sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua \
--mysql-user=user --mysql-password='passwd' --mysql-port=3306 \
--mysql-host=192.168.1.22 --oltp-tables-count=16 --num-threads=8 cleanup
```

上面是整个思路过程，下面就来看看代码吧

```
#!/bin/sh
 
#通过sysbench测试mysql相关性能，并将关键数据存储于‘test.sysbenc_test’表中
 
#定义记录测试结果的mysql连接相关参数，本例我在测试机上记录测试结果
m_user='test'
m_passwd='test'
m_port='3307'
m_host='127.0.0.1'
 
#定义错误日志文件
log=/tmp/mysql_oltp.log
#定义测试线程
threds_num='8 24 48 64 96 128 160 196 256'
 
#测试函数
sb_test() {
 
    #定义测试方式相关变量
    tables_count=16    #测试表的数量
    if [ "$3" == "read-only" ];then read_only='on';else read_only='off';fi    #根据脚本参数确定是否read-only
 
    #创建记录测试信息的表
    echo -e "\n---------------\n创建测测试结果表test.sysbench_test\n---------------"
    mysql -u$m_user -p$m_passwd -P$m_port -h$m_host <<EOF
        CREATE TABLE IF NOT EXISTS test.sysbench_test (
        scenario varchar(30) NOT NULL DEFAULT '' COMMENT '测试场景',
        server_name varchar(15) NOT NULL COMMENT '被测DB name',
        test_type varchar(15) NOT NULL COMMENT 'read-only,read-write,insert等',
        sb_threads int(11) NOT NULL DEFAULT '0' COMMENT 'sysbench 测试线程',
        server_load decimal(12,2) NOT NULL DEFAULT '0.00' COMMENT '以当前线程测试完后立刻记录一分钟负载值',
        request_total int(11) NOT NULL DEFAULT '0',
        request_read int(11) NOT NULL DEFAULT '0',
        request_write int(11) NOT NULL DEFAULT '0',
        request_per_second decimal(12,2) NOT NULL DEFAULT '0.00',
        total_time decimal(12,2) NOT NULL DEFAULT '0.00' COMMENT '单位秒',
        95_pct_time decimal(12,2) NOT NULL DEFAULT '0.00' COMMENT '单位毫秒'
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8;
EOF
    if [ $? -ne 0 ];then exit -1;fi
 
    #开始测试,每种条件测3次,分析时取平均值
    echo -e "\n---------------\n场景:$2 模式:$3\n---------------"
    for i in {1..3};do
         
        for sb_threds in $threds_num;do    #按照指定的sysbench线程测试
            printf "  %-10s %s\n" $sb_threds线程 第$i次运行...
             
            #result 作为每次最小测试单元的结果，根据sysbench测试结果各参数的出现顺序，以request_read、request_write、request_total、request_per_second、total_time、95_pct_time为顺序插入表中。下条命令中，egerp之后的操作是为了对sysbench的输出做筛选和格式化，以便插入数据库
            sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua --mysql-user=$6 --mysql-password=$7 --mysql-port=$5 --mysql-host=$4 --num-threads=$sb_threds run --oltp-skip-trx=on --oltp-read-only=$read_only > $log
            if [ $? -ne 0 ];then
                echo -e "\nSysbench error! For more information see $log"
                exit -1
            fi
            result=$(cat $log | egrep  "read:|write:|read/write.*:|total:|total\ time:|approx\..*95.*:" |sed -r -e "s/[0-9]+ \(//g" -e "s/\ per sec\.\)//g" -e "s/m?s$//g" | awk  '{printf("%s ",$NF)}'|sed "s/\ /,/g" | sed "s/,$//g")
 
            #测试完成后立刻记录系统一分钟负载值，可近似认为测试过程中proxy的负载抽样
            load=$(ssh -p22 $4 "uptime|awk -F: '{print \$NF}'|awk -F, '{print \$1}'" 2>/dev/null)
 
            #本次测试结果写入数据库
            mysql -u$m_user -p$m_passwd -P$m_port -h$m_host <<EOF 2> $log
                INSERT INTO test.sysbench_test (scenario,server_name,test_type,sb_threads,server_load,request_read,request_write,request_total,request_per_second,total_time,95_pct_time) 
                VALUES ('$2','$4','$3','$sb_threds','$load',$result);
EOF
     
            if [ $? -ne 0 ];then
                echo -e "\n----------$sb_threds线程测试，第$i次插入数据库时失败----------"
                echo "INSERT VALUES ('$2','$4','$3',$sb_threds,$load,$result)"
                exit -2
            fi
            sleep 60    #让库歇一会，也让一分钟负载能够恢复到测试前的值
        done
 
    done
}
 
#结果分析函数
sb_analyse() {
     mysql -u$m_user -p$m_passwd -h$m_host -P$m_port <<EOF 2> $log
        SELECT
        scenario, 
        server_name,
        test_type,
        sb_threads,
        convert(avg(server_load),decimal(12,2)) as server_load,
        convert(avg(request_total),decimal(12,0)) as request_total,
        convert(avg(request_read),decimal(12,0)) as request_read,
        convert(avg(request_write),decimal(12,0)) as request_write,
        convert(avg(request_per_second),decimal(12,2)) as request_per_second,
        convert(avg(total_time),decimal(12,2)) as total_time,
        convert(avg(95_pct_time),decimal(12,2)) as 95_pct_time
        FROM test.sysbench_test group by scenario,server_name,test_type,sb_threads
EOF
}
 
#画图函数
sb_chart() {
    sb_analyse > /tmp/mysql_oltp.dat
 
    for chart_type in "request_per_second" "total_time" "95_pct_time";do    #这里写死了关注的三个指标，也就是会画三张图
 
        col_num=0    #该行及下面这个for循环用于取得三个指标在数据中的列号
        for col_name in `cat /tmp/aualyse.txt |awk 'NR<2 {print}'`;do
            let col_num++
            if [ $col_name == $chart_type ];then break;fi
        done
         
        if [ $chart_type == "request_per_second" ];then    #根据图表特点为不同的chart_type设置不同的key position
            key_pos="bottom right"
            unit=""
        elif [ $chart_type == "total_time" ];then
            key_pos="top right"
            unit="(s)"
        elif [ $chart_type == "95_pct_time" ];then
            key_pos="top left"
            unit="(ms)"
        fi
 
        plot_cmd="set term png size 800,600;set output '/tmp/$chart_type.png';set title '$chart_type $unit';set grid;set key $key_pos;plot "
         
        if [ $# -eq 0 ];then
            #对分析结果中所有场景进行画图
            for scenario in `mysql -u$m_user -p$m_passwd -h$m_host -P$m_port -s -e "select distinct(scenario) from test.sysbench_test" 2>/dev/null`;do
                sb_analyse | awk -v scenario=$scenario '$1 == scenario {print}' > /tmp/"$scenario.dat"
                plot_cmd=${plot_cmd}"'/tmp/"$scenario.dat"' using $col_num:xtic(4) title '$scenario' with linespoints lw 2,"
            done
            plot_cmd=$(echo $plot_cmd | sed 's/,$//g')
            echo $plot_cmd | gnuplot
        else
            #只绘制指定的场景
            for scenario in $*;do
                sb_analyse | awk -v scenario=$scenario '$1 == scenario {print}' > /tmp/"$scenario.dat"
                plot_cmd=${plot_cmd}"'/tmp/"$scenario.dat"' using $col_num:xtic(4) title '$scenario' with linespoints lw 2,"
            done
            plot_cmd=$(echo $plot_cmd | sed 's/,$//g')
            echo "$plot_cmd" | gnuplot
        fi
    done
}
 
#脚本使用说明/参数判断
if [ $# -eq 1 ] && [ $1 == "-h" -o $1 == "--help" ];then
    echo -e "\nUsage: $0 {test test_scenario test_type mysql_host mysql_port mysql_user mysql_password} | {analyse} | {chart [scenario]...}\n"
    echo ----------
    echo -e "测试: 请在脚本后跟上 test test_scenario test_type mysql_host mysql_port mysql_user mysql_password 7个参数 ！"
    echo -e "      test_type: read-only 或 read-write, 表示测试模式"
    echo -e "      其余4参数表示待测试MySQL连接相关信息,密码若包含特殊字符,将其置于单引号内"
    echo -e "----------"
    echo -e "分析: 请在脚本后跟上 analyse"
    echo -e "----------"
    echo -e "画图: 请在脚本后面跟上"
    echo -e "      会在/tmp/下生成request_per_second.png total_time.png 95_pct_time.png 三张图"        
    echo -e "      chart (对分析结果中的所有测试场景画图)"
    echo -e "      chart scenario ... (对指定的测试场景画图，场景名可查看analyse)\n"
    exit -1
elif [ "$1" == "test" -a  $# -eq 7 ];then
    sb_test $1 $2 $3 $4 $5 $6 $7
elif [ "$1" == "analyse" -a $# -eq 1 ];then
    sb_analyse
elif [ "$1" == "chart" ];then
    #chart函数可不接参数,也可接任意个'测试场景'作为参数
    arg=($*)
    arg_len=${#arg[@]}
    sb_chart ${arg[@]:1:$arg_len-1}
else
    echo -e "\nUsage: $0 {test test_scenario test_type mysql_host mysql_port mysql_user mysql_password} | {analyse} | {chart [scenario]...}\n"
fi
 
### by ljk 2016/10/14
```
