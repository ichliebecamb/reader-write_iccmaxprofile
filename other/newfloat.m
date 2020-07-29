function out=newfloat(x)
x_size=size(x);
out=zeros(1,4*x_size(1,2));
for i=1:x_size(1,2)
    if x(1,i)>1
        out(1+(i-1)*4:4+(i-1)*4)=iszhengshu(x(1,i));
    elseif x(1,i)==1
        out(1+(i-1)*4:4+(i-1)*4)=[63,128,0,0];
    else
        out(1+(i-1)*4:4+(i-1)*4)=isxiaoshu(x(1,i));
    end
end

function out=iszhengshu(x)
if(mod(x,1)==0)%判断输入是否为整数,mod为取余函数
    numint=dec2bin(x);
    numint=double(numint)-48;     % 纯整数二进制
    a=size(numint);
    a=a(1,2);
    weishu=zeros(1,a-1);
    for zhengshu=1:a-1
        weishu(1,zhengshu)=numint(1,zhengshu+1);
    end %得到整数部分的尾数
    e=127+zhengshu;
    numint=dec2bin(e);
    jie=double(numint)-48; %阶数的二进制
    d=size(jie);
    jieshu=zeros(1,8);
    for c=1:d(1,2)
        jieshu(1,9-c)=jie(1,d(1,2)+1-c);
    end % 8位的阶数表达
    b=[0,jieshu,weishu];
    c=size(b);
    if c(1,2)<24
        b=[b,zeros(1,24)];
    end
    part1=0;part2=0;part3=0;part4=0;
    for e=1:8
        part1=part1+2^(8-e)*b(1,e);
        part2=part2+2^(8-e)*b(1,8+e);
        part3=part3+2^(8-e)*b(1,16+e);
        part4=part4+2^(8-e)*b(1,24+e);
    end
else%输入为非整数的情况
    nint=floor(x);%整数部分
    nf=x-nint;%小数部分
    res_nint=dec2bin(nint);
    res_nint=double(res_nint)-48; %整数部分的二进制
    a=size(res_nint);
    a=a(1,2);
    weishu=zeros(1,a-1);
    for zhengshu=1:a-1
        weishu(1,zhengshu)=res_nint(1,zhengshu+1);
    end %得到整数部分的尾数
    count=panduanjieshu(nf);
    res_int=chunxiaoshu(nf,count);      %小数部分二进制
    e=127+zhengshu; %阶数
    numint=dec2bin(e);
    jie=double(numint)-48; %阶数的二进制
    d=size(jie);
    jieshu=zeros(1,8);
    for c=1:d(1,2)
        jieshu(1,9-c)=jie(1,d(1,2)+1-c);
    end % 8位的阶数表达
    b=[0,jieshu,weishu,res_int];
    c=size(b);
    if c(1,2)<24
        b=[b,zeros(1,24-c(1,2))];
    end
    part1=0;part2=0;part3=0;part4=0;
    for e=1:8
        part1=part1+2^(8-e)*b(1,e);
        part2=part2+2^(8-e)*b(1,8+e);
        part3=part3+2^(8-e)*b(1,16+e);
        part4=part4+2^(8-e)*b(1,24+e);
    end
end; 
out=[part1,part2,part3,part4];
function out=isxiaoshu(x)
if x==0
    out=[0,0,0,0];
elseif x<0
    ret=newfloat(-x);
    ret(1,1)=ret(1,1)+128;
    out=ret;
else
    count=panduanjieshu(x);
    res=chunxiaoshu(x,count);      %小数部分二进制
    a=size(res);
    a=a(1,2);
    %计算纯小数的尾数
    weishu=zeros(1,a-count);
    for c=1:23
        weishu(1,c)=res(1,count+c);
    end
    e=127-count;
    numint=dec2bin(e);
    jie=double(numint)-48; %阶数的二进制
    d=size(jie);
    jieshu=zeros(1,8);
    for c=1:d(1,2)
        jieshu(1,9-c)=jie(1,d(1,2)+1-c);
    end % 8位的阶数表达
    b=[0,jieshu,weishu];
    c=size(b);
    if c(1,2)<24
        b=[b,zeros(1,24-c(1,2))];
    end
    part1=0;part2=0;part3=0;part4=0;
    for e=1:8
        part1=part1+2^(8-e)*b(1,e);
        part2=part2+2^(8-e)*b(1,8+e);
        part3=part3+2^(8-e)*b(1,16+e);
        part4=part4+2^(8-e)*b(1,24+e);
    end
    out=[part1,part2,part3,part4];
end
function res_int=chunxiaoshu(nf,count)
number=nf*2^(24+count);
number=floor(number);
numint=dec2bin(number);
numint=double(numint)-48;     % 纯整数二进制
a=size(numint);
b=zeros(1,count+a(1,2));
for c=1:24
    b(1,count-1+c)=numint(1,c);
end
res_int=b;
function count=panduanjieshu(x)
%首先判断阶数 count就是阶数
count=0;
tempnum=x;
N=23;
while(N)
    count=count+1;
    %长度小于N
    if(count>N)
        N=0;
    end
    tempnum=tempnum*2;
    %小数转换为二进制,乘2取整
    if tempnum>1
        N=0;
        tempnum=tempnum-1;
    elseif(tempnum==1)
        N=0;
    end
end