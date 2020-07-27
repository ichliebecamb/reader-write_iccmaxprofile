# reader_iccmaxprofile
本仓库利用matlab编写了对新版本特性文件的读写功能，仅仅为了学习icc.2特性文件的结构。
本文件是在matlab软件自带函数 iccread.m 和 iccwrite.m 的基础之上修改而来。
为了保证与文件生成程序的相互兼容，一些公共组分将放在另一个仓库中
其用法为：  
>> dataname = iccmaxread('filepath');
