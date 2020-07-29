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
if(mod(x,1)==0)%�ж������Ƿ�Ϊ����,modΪȡ�ຯ��
    numint=dec2bin(x);
    numint=double(numint)-48;     % ������������
    a=size(numint);
    a=a(1,2);
    weishu=zeros(1,a-1);
    for zhengshu=1:a-1
        weishu(1,zhengshu)=numint(1,zhengshu+1);
    end %�õ��������ֵ�β��
    e=127+zhengshu;
    numint=dec2bin(e);
    jie=double(numint)-48; %�����Ķ�����
    d=size(jie);
    jieshu=zeros(1,8);
    for c=1:d(1,2)
        jieshu(1,9-c)=jie(1,d(1,2)+1-c);
    end % 8λ�Ľ������
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
else%����Ϊ�����������
    nint=floor(x);%��������
    nf=x-nint;%С������
    res_nint=dec2bin(nint);
    res_nint=double(res_nint)-48; %�������ֵĶ�����
    a=size(res_nint);
    a=a(1,2);
    weishu=zeros(1,a-1);
    for zhengshu=1:a-1
        weishu(1,zhengshu)=res_nint(1,zhengshu+1);
    end %�õ��������ֵ�β��
    count=panduanjieshu(nf);
    res_int=chunxiaoshu(nf,count);      %С�����ֶ�����
    e=127+zhengshu; %����
    numint=dec2bin(e);
    jie=double(numint)-48; %�����Ķ�����
    d=size(jie);
    jieshu=zeros(1,8);
    for c=1:d(1,2)
        jieshu(1,9-c)=jie(1,d(1,2)+1-c);
    end % 8λ�Ľ������
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
    res=chunxiaoshu(x,count);      %С�����ֶ�����
    a=size(res);
    a=a(1,2);
    %���㴿С����β��
    weishu=zeros(1,a-count);
    for c=1:23
        weishu(1,c)=res(1,count+c);
    end
    e=127-count;
    numint=dec2bin(e);
    jie=double(numint)-48; %�����Ķ�����
    d=size(jie);
    jieshu=zeros(1,8);
    for c=1:d(1,2)
        jieshu(1,9-c)=jie(1,d(1,2)+1-c);
    end % 8λ�Ľ������
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
numint=double(numint)-48;     % ������������
a=size(numint);
b=zeros(1,count+a(1,2));
for c=1:24
    b(1,count-1+c)=numint(1,c);
end
res_int=b;
function count=panduanjieshu(x)
%�����жϽ��� count���ǽ���
count=0;
tempnum=x;
N=23;
while(N)
    count=count+1;
    %����С��N
    if(count>N)
        N=0;
    end
    tempnum=tempnum*2;
    %С��ת��Ϊ������,��2ȡ��
    if tempnum>1
        N=0;
        tempnum=tempnum-1;
    elseif(tempnum==1)
        N=0;
    end
end