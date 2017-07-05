#!/bin/sh
#by ljk 20161003
 
#通过sysbench测试mysql相关性能，并将关键数据存储于‘test.sysbenc_test’表中

#----------自定义部分----------
#定义记录测试结果的mysql连接相关参数，本例我在测试机上记录测试结果
m_user='test'
m_passwd='test'
m_port='3306'
m_host='127.0.0.1'
#测试结果存储于哪个库
m_db='test'
#测试结果存储于哪个表
m_table='sysbench_test'

#sysbench lua脚本目录
lua_dir=/usr/share/doc/sysbench/tests/db

#画图维度（关注的三个指标，也就是会画三张图）
target="request_per_second total_time 95_pct_time"

#定义错误日志文件
log=/tmp/mysql_oltp.log
#定义分析结果文件
data=/tmp/mysql_oltp.dat

#定义测试线程
threds_num='8 24 48 64 96 128 160 196 256'
#每种场景的测试次数，分析时取平均值
times=3
#----------自定义部分结束---------- 

#测试函数
sb_test() {
 
    #定义测试方式相关变量
    tables_count=16    #测试表的数量
    if [ "$3" == "read-only" ];then read_only='on';else read_only='off';fi    #根据脚本参数确定是否read-only
 
    #创建记录测试信息的表
    echo -e "\n---------------\n创建测测试结果表$m_db.$m_table\n---------------"
    mysql -u$m_user -p$m_passwd -P$m_port -h$m_host <<EOF
        CREATE TABLE IF NOT EXISTS $m_db.$m_table (
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
    if [ $? -ne 0 ];then
        echo "create table $m_db.$m_table failed"
        exit -1
    fi

    #开始测试,每种条件测$times次,分析时取平均值
    echo -e "\n---------------\n场景:$2 模式:$3\n---------------"
    for i in `seq $times`;do
        for sb_threds in $threds_num;do    #按照指定的sysbench线程测试
            printf "  %-10s %s\n" $sb_threds线程 第$i次运行...
             
            #result 作为每次最小测试单元的结果，根据sysbench测试结果各参数的出现顺序
            #以request_read、request_write、request_total、request_per_second、total_time、95_pct_time为顺序插入表中
            #下条命令中，egerp之后的操作是为了对sysbench的输出做筛选和格式化，以便插入数据库
            sysbench --test=$lua_dir/oltp.lua --mysql-user=$6 --mysql-password=$7 --mysql-port=$5 --mysql-host=$4 \
                     --num-threads=$sb_threds run --oltp-skip-trx=on --oltp-read-only=$read_only &> $log
            if [ $? -ne 0 ];then
                echo -e "\nSysbench error! For more information see $log"
                exit -1
            fi
            result=$(cat $log | egrep  "read:|write:|read/write.*:|total:|total\ time:|approx\..*95.*:" | sed -r -e "s/[0-9]+ \(//g" -e "s/\ per sec\.\)//g" -e "s/m?s$//g"| awk  '{printf("%s 
",$NF)}' | sed "s/\ /,/g" | sed "s/,$//g")
 
            #测试完成后立刻记录系统一分钟负载值，可近似认为测试过程中proxy的负载抽样
            load=$(ssh -p22 $4 "uptime|awk -F: '{print \$NF}'|awk -F, '{print \$1}'" 2>/dev/null)
 
            #本次测试结果写入数据库
            mysql -u$m_user -p$m_passwd -P$m_port -h$m_host <<EOF
                INSERT INTO $m_db.$m_table (scenario,server_name,test_type,sb_threads,server_load,request_read,
                                            request_write,request_total,request_per_second,total_time,95_pct_time) 
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
     mysql -u$m_user -p$m_passwd -h$m_host -P$m_port <<EOF 2>&1|grep -v 'password on the command line'
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
        FROM $m_db.$m_table group by scenario,server_name,test_type,sb_threads
EOF
}
 
#画图函数
sb_chart() {
    sb_analyse >$data
 
    for chart_type in $target;do
        col_num=0    #该行及下面这个for循环用于取得三个指标在数据中的列号
        for col_name in `cat $data |awk 'NR<2 {print}'`;do
            let col_num++
            if [ $col_name == $chart_type ];then break;fi
        done
         
        if [ $chart_type == "request_per_second" ];then    #根据图表特点为不同的chart_type设置gunplot不同的key position
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
            for scenario in `mysql -u$m_user -p$m_passwd -h$m_host -P$m_port -s -e "select distinct(scenario) from $m_db.$m_table" 2>/dev/null`;do
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
    echo -e "\nUsage: $0 test (test_scenario) (test_type) (mysql_host) (mysql_port) (mysql_user) (mysql_password)\n       $0 analyse\n       $0 chart [scenario]...\n"
    echo ----------
    echo -e "测试: 子命令test"
    echo -e "      test_scenario: 自定义的测试场景名"
    echo -e "      test_type: read-only 或 read-write, 表示测试模式"
    echo -e "      其余4参数表示待测试MySQL连接相关信息,密码若包含特殊字符,将其置于单引号内"
    echo -e "----------"
    echo -e "分析: 子命令analyse"
    echo -e "----------"
    echo -e "画图: 子命令chart"
    echo -e "      会在/tmp/下生成request_per_second.png total_time.png 95_pct_time.png 三张图"        
    echo -e "      chart (对分析结果中的所有测试场景画图)"
    echo -e "      chart scenario ... (对指定的测试场景画图，场景名依据先前自定义的名称)\n"
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
    echo -e "\nUsage: $0 test (test_scenario) (test_type) (mysql_host) (mysql_port) (mysql_user) (mysql_password)\n       $0 analyse\n       $0 chart [scenario]...\n"
fi
