function out=uint2float_xyz_number(x)
out=zeros(1,3);
out(1,1)=four2one(x(1:4,1));
out(1,2)=four2one(x(5:8,1));
out(1,3)=four2one(x(9:12,1));
function out=four2one(x1)
x=[x1;128];
numint=dec2bin(x);
numint=double(numint)-48;     % 纯整数二进制
all_number=[numint(1,:),numint(2,:),numint(3,:),numint(4,:)];
E=0;T=0;
for i=1:8
    E=E+all_number(1,1+i)*2^(8-i);
end
E=E-127;
for j=1:23
    T=T+all_number(1,9+j)*2^(23-j);
end
T=T+2^23;
out=(-1)^all_number(1,1)*2^E*T/2^23;