function p_new = iccmaxwrite(p, filename)
%ICCWRITE Write ICC color profile.
%   P_NEW = ICCWRITE(P, FILENAME) writes the International Color Consortium
%   (ICC) color profile data from the profile structure specified by P to
%   the file specified by FILENAME.
%
%   P is a structure representing an ICC profile in the data format
%   returned by ICCREAD and used by MAKECFORM and APPLYCFORM to compute
%   color-space transformations.  It must contain all tags and fields
%   required by the ICC profile specification.  Some fields may be
%   inconsistent, however, because of interactive changes to the structure.
%   For instance, the tag table may not be correct because tags may have
%   been added, deleted, or modified since the tag table was constructed.
%   Hence, any necessary corrections will be made to the profile structure
%   before the profile is written to the file.  The corrected structure
%   is returned as P_NEW.
%
%   The VERSION field in P.HEADER is used to determine which version of the
%   ICC spec to follow in formatting the profile for output.  Both Version
%   2 and Version 4 are supported. 
%
%   The reference page for ICCREAD has additional information about the
%   fields of the structure P.  For complete details, see the
%   specification ICC.1:2001-04 for Version 2 and ICC.1:2001-12 for 
%   Version 4 (www.color.org).
%
%   Example
%   -------
%   Write a monitor profile.
%
%       P = iccread('monitor.icm');
%       pmon = iccwrite(P, 'monitor2.icm');
%
%   See also ISICC, ICCREAD, MAKECFORM, APPLYCFORM.

%   Copyright 2003-2015 The MathWorks, Inc.

validateattributes(filename, {'char'}, {'nonempty'}, 'iccwrite', 'FILENAME', 2);
% if ~isiccmax (p)
%     error(message('images:iccwrite:invalidProfile'))
% end

% Open (create) file for writing 以二进制的方法打开文件
[fid, msg] = fopen(filename, 'w+', 'b');
if (fid < 0)
    error(message('images:iccwrite:errorOpeningFile', filename, msg));
end

% Write profile data to file and update structure  输出iccmax文件的主程序
p_new = write_profile(fid, p);
fclose(fid); % 关闭以二进制方式打开的文件
p_new.Filename = filename; %将输出的数据显示在命令行窗口上

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function pnew = write_profile(fid, p)
%   WRITE_PROFILE(FID, P) writes ICC profile data to the file with
%   identifier FID from input structure P and returns updated structure
%   PNEW.

% Initialize output structure
pnew = p;

% Determine version of ICC spec 获取文件的主版本号
version = sscanf(p.Header.Version(1), '%d%');

% Encode tags in byte vector and construct new tag table 
% 将标签用字节表示和创建一个新标签表
[tagtable, tagheap] = encode_tags(p, version);
if isempty(tagheap)
    fclose(fid);
    error(message('images:iccwrite:InvalidTags'))
end

% Compute and update sizes and offsets
numtags = size(tagtable, 1);
base_offset = 128 + 4 + 12 * numtags;
          % = length(header) + length(tag table)
for k = 1:numtags
    tagtable{k, 2} = tagtable{k, 2} + base_offset;
end
pnew.Header.Size = base_offset + length(tagheap);

pnew.TagTable = tagtable;

% Encode header and tag table as byte vectors
headerheap = uint8(encode_header(pnew.Header));
% 判断头文件是否为空
if isempty(headerheap)
    fclose(fid);
    error(message('images:iccwrite:InvalidHeader'))
end
tableheap = uint8(encode_tagtable(tagtable));
if isempty(tableheap)
    fclose(fid);
    error(message('images:iccwrite:InvalidTagTable'))
end

% Assemble profile as byte vector and write to file
profileheap = uint8([headerheap, tableheap, tagheap]);
if version > 2  
    % Compute MD5 checksum for profile; see clause 6.1.13.
    % Spec says to compute the checksum after setting bytes
    % 44-47 (indexed from 0), 64-67, and 84-99 to 0.
    tempheap = profileheap;
    tempheap([45:48 65:68 85:100]) = 0;
    pnew.Header.ProfileID = compute_md5(tempheap);
    profileheap(85:100) = pnew.Header.ProfileID;
end

fwrite_check(fid, profileheap, 'uint8');

%-----------------------------------------------------
function out = encode_tagtable(tagtable)
% Convert TagTable field into byte stream for profile

% Allocate space; insert tag count
numtags = size(tagtable, 1);
out = uint8(zeros(1, 4 + 12 * numtags));
out(1:4) = longs2bytes(uint32(numtags));
offset = 4;

% Insert signature, offset, and data_size for each tag
for k = 1:numtags
    % iccread deblanks signatures. Make sure the signature here
    % has four characters, padded with blanks if necessary.
    sig = '    ';
    P = length(tagtable{k, 1});
    sig(1:P) = tagtable{k, 1};
    out((offset + 1):(offset + 4)) = uint8(sig);
    out((offset + 5):(offset + 8)) = longs2bytes(uint32(tagtable{k, 2}));
    out((offset + 9):(offset + 12)) = longs2bytes(uint32(tagtable{k, 3}));
    offset = offset + 12;
end

%-----------------------------------------------------
%%% encode_tags
function [tag_table, tagheap] = encode_tags(p, version)
% Encode all public and private tags into byte stream,
% recording their locations, etc., in a new tag table

% Count public tags -- all fields except Filename, 
% Header, TagTable, and PrivateTags should count
profile_fields = fieldnames(p); 
if isfield(p, 'MatTRC')
    mattrc_fields = fieldnames(p.MatTRC);
else
    mattrc_fields = {};
end

public_tagnames = get_icc_public_tagnames(version);
mattrc_tagnames = get_mattrc_tagnames(version);

publiccount = count_matching_fields(profile_fields, public_tagnames(:, 2)) + ...
              count_matching_fields(mattrc_fields, mattrc_tagnames(:, 2));

% Count private tags
privatecount = size(p.PrivateTags, 1);

% Allocate space
tag_table = cell(publiccount + privatecount, 3);
tagrow = 1;
tagheap = uint8(zeros(1, 0));     % empty 1-row array
offset = 0;

% Process public tags 编码所有的标签
for k = 1:length(profile_fields)
    pdx = strmatch(profile_fields{k}, public_tagnames(:, 2), 'exact');
    if ~isempty(pdx)
        signature = public_tagnames{pdx, 1};
        % 公共标签编写主程序
        tag = encode_public_tag(signature, p.(profile_fields{k}), ...
                                p.Header.ConnectionSpace, version);
        if isempty(tag)
            warning(message('images:iccwrite:DefectiveTag', profile_fields{ k }))
            tagheap = [];
            return;
        end

        data_size = length(tag);     % without padding
        
        sigmatch = find_signature_matches(signature, tagrow, tag_table);
        % ==> sigmatch contains row numbers of possible matching tags

        matchrow = find_matching_tags(sigmatch, tag, tag_table, tagheap);
        
      % Add row to Tag Table, either for alias or new tag:
        if matchrow ~= 0            % alias to previous tag
            tag_table{tagrow, 1} = signature;
            tag_table{tagrow, 2} = tag_table{matchrow, 2};
            tag_table{tagrow, 3} = tag_table{matchrow, 3};
        else                        % add new tag
            tag = bump(tag);            % pad to 32-bit boundary
            % append to heap
            tagheap = [tagheap, tag];   %#ok<AGROW> 
            tag_table{tagrow, 1} = signature;
            tag_table{tagrow, 2} = offset;
            tag_table{tagrow, 3} = data_size;   % unpadded length
            offset = offset + length(tag);      % includes padding
        end
        tagrow = tagrow + 1;
    end
end

for k = 1:length(mattrc_fields)
    mdx = strmatch(mattrc_fields{k}, mattrc_tagnames(:, 2), 'exact');
    if ~isempty(mdx)
        signature = mattrc_tagnames{mdx, 1};
        tag = encode_public_tag(signature, p.MatTRC.(mattrc_fields{k}), ...
                                p.Header.ConnectionSpace, version);
        if isempty(tag)
            error(message('images:iccwrite:DefectiveTag', mattrc_fields{ k }))
        end
        data_size = length(tag);
        tag = bump(tag);
        tagheap = [tagheap, tag]; %#ok<AGROW> 
        tag_table{tagrow, 1} = signature;
        tag_table{tagrow, 2} = offset;
        tag_table{tagrow, 3} = data_size;
        offset = offset + length(tag);
        tagrow = tagrow + 1;
    end
end

% Process private tags 私有标签
for k = 1:privatecount
    signature = p.PrivateTags{k, 1};
    tag = encode_private_tag(p.PrivateTags{k, 2});
    if isempty(tag)
        warning(message('images:iccwrite:DefectiveTagPrivate', signature))
        tagheap = [];
        return;
    end
    data_size = length(tag);
    tag = bump(tag);
    tagheap = [tagheap, tag]; %#ok<AGROW>
    tag_table{tagrow, 1} = signature;
    tag_table{tagrow, 2} = offset;
    tag_table{tagrow, 3} = data_size;
    offset = offset + length(tag);
    tagrow = tagrow + 1;
end

%-----------------------------------------------------
function count = count_matching_fields(fields, tagnames)
% Return a count of the number of profile fields that match one or more
% entries in the provided list if tagnames.

count = 0;
for k = 1:length(fields)
    idx = strmatch(fields{k}, tagnames, 'exact');
    if ~isempty(idx)
        count = count + 1;
    end
end


%-----------------------------------------------------
function sigmatch = find_signature_matches(signature, tag_row, tag_table)
% If signature starts with 'A2B', find other tags in the first tag_row-1
% entries in the tag table starting with 'A2B'.
%
% If signature starts with 'B2A', find other tags in the first tag_row-1
% entries in the tag table starting with 'B2A'.
%
% sigmatch is a vector of indices into the tag table.

if strcmp(signature(1 : 3), 'A2B')
    sigmatch = strmatch('A2B', tag_table(1 : tag_row - 1, 1));
elseif strcmp(signature(1 : 3), 'B2A')
    sigmatch = strmatch('B2A', tag_table(1 : tag_row - 1, 1));
else
    sigmatch = [];
end

%-----------------------------------------------------
function idx = find_matching_tags(signature_matches, tag, tag_table, tag_heap)
% Test tag data against other tags in the tag_table with matching
% signatures.  signature_matches is a vector of indices into tag_table. tag
% is the tag data being tested.  tag_heap is the binary table of all tag
% data constructed so far.
%
% Returns idx, a scalar value.  If a match was found, idx is the index into
% tag_table of the corresponding tag.  If no match is found, idx is 0.

tag_size = numel(tag);
idx = 0;
for j = 1:numel(signature_matches)
    matchoff = tag_table{signature_matches(j), 2};
    if tag_table{signature_matches(j), 3} == tag_size && ...
            all(tag_heap(matchoff + 1 : matchoff + tag_size) == tag)
        idx = signature_matches(j);
        break
    end
end



%-----------------------------------------------------
function out = encode_header(header)
% Encode header fields in byte stream for profile

out = uint8(zeros(1, 128));     % fixed-length header

% Clause 6.1.1 - Profile size
out(1:4) = longs2bytes(uint32(header.Size));

% Clause 6.1.2 - CMM Type
out(5:8) = uint8(header.CMMType);

% Clause 6.1.3 - Profile Version
% Byte 0:  Major Revision in BCD
% Byte 1:  Minor Revision & Bug Fix Revision in each nibble in BCD
% Byte 2:  Reserved; expected to be 0
% Byte 3:  Reserved; expected to be 0

version_numbers = sscanf(header.Version, '%d.%d.%d');
out(9) = uint8(version_numbers(1));
out(10) = uint8(16 * version_numbers(2) + version_numbers(3));

% Clause 6.1.4 - Profile/Device Class signature
% Device Class             Signature
% ------------             ---------
% Input Device profile     'scnr'
% Display Device profile   'mntr'
% Output Device profile    'prtr'

device_classes = get_iccmax_device_classes(version_numbers(1));
idx = strmatch(header.DeviceClass, device_classes(:, 2), 'exact');
if isempty(idx)
    out = [];
    return;
end
out(13:16) = uint8(device_classes{idx, 1});

% Clause 6.1.5 - Color Space signature
% Four-byte string, although some of signatures have a blank
% space at the end.
colorspaces = get_iccmax_colorspaces(version_numbers(1));
idx = strmatch(header.ColorSpace, colorspaces(:, 2), 'exact');
if isempty(idx)
    out = [];
    return;
end
out(17:20) = uint8(colorspaces{idx, 1});

% Clause 6.1.6 - Profile connection space signature
% Either 'XYZ' or 'Lab'.  However, if the profile is a DeviceLink
% profile, the connection space signature is taken from the
% colorspace signatures table.  
idx = strmatch(header.ConnectionSpace, colorspaces(:, 2), 'exact');
if isempty(idx)
    out = [];
    return;
% elseif ~strcmp(header.DeviceClass, 'device link') && idx > 2
%    out = [];          % for non-DeviceLink, must be PCS
%    return;
else
    out(21:24) = uint8(colorspaces{idx, 1});
end

date_time_num = datevec(header.CreationDate);
out(25:36) = encode_date_time_number(uint16(date_time_num));

if ~strcmp(header.Signature, 'acsp')
    out = [];
    return;
else
    out(37:40) = uint8('acsp');
end

% Clause 6.1.7 - Primary platform signature
% Four characters, though one code ('SGI ') ends with a space.
% Zeros if there is no primary platform.
switch header.PrimaryPlatform
    case 'none'
        out(41:44) = [0 0 0 0];
    case 'SGI'
        out(41:44) = uint8('SGI ');
    case 'Apple'
        out(41:44) = uint8('APPL');
    case 'Microsoft'
        out(41:44) = uint8('MSFT');
    case 'Sun'
        out(41:44) = uint8('SUNW');
    case 'Taligent'
        out(41:44) = uint8('TGNT');
    otherwise
        if numel(header.PrimaryPlatform) == 4
            out(41:44) = uint8(header.PrimaryPlatform);
            warning(message('images:iccwrite:invalidPrimaryPlatform'));
        else      
            out = [];
            return;
        end
end

% Clause 6.1.8 - Profile flags
% Flags containing CMM hints.  The least-significant 16 bits are reserved
% by ICC, which currently defines position 0 as "0 if not embedded profile,
% 1 if embedded profile" and position 1 as "1 if profile cannot be used
% independently of embedded color data, otherwise 0."
out(45:48) = uint8(longs2bytes(uint32(header.Flags)));

% Clause 6.1.9 - Device manufacturer and model
out(49:52) = uint8(header.DeviceManufacturer);
out(53:56) = uint8(header.DeviceModel);

% Clause 6.1.10 - Attributes
% Device setup attributes, such as media type.  The least-significant 32
% bits of this 64-bit value are reserved for ICC, which currently defines
% bit positions 0 and 1.  

% UPDATE FOR ICC:1:2001-04 Clause 6.1.10 -- Bit positions 2 and 3 
% POSITION 2: POSITIVE=0, NEGATIVE=1
% POSITION 3: COLOR=0, BLACK AND WHT=1

out(57:60) = uint8([0 0 0 0]);
out(61:64) = longs2bytes(uint32(header.Attributes));

% Clause 6.1.11 - Rendering intent
switch header.RenderingIntent
    case 'perceptual'
        value = 0;
    case 'relative colorimetric'
        value = 1;
    case 'saturation'
        value = 2;
    case 'absolute colorimetric'
        value = 3;
    otherwise
        out = [];
        return;
end
out(65:68) = longs2bytes(uint32(value));

% Clause 6.1 - Table 9
out(69:80) = encode_xyz_number(header.Illuminant);

% Clause 6.12 - Profile creator
out(81:84) = uint8(header.Creator);

% Spectral PCS field (Bytes 100 to 103)
out(101:104) = uint8(header.SpectralPCS.val);
% Spectral PCS Range field (Bytes 104 to 109)
out(105:106)= newfl16(header.SpectralPCSRange.Start);
out(107:108)= newfl16(header.SpectralPCSRange.End);
out(109:110)= shorts2bytes(header.SpectralPCSRange.Step);
% Bi-Spectral PCS Range field (Bytes 110 to 115)
out(111:112)= newfl16(header.BIPCSRange.Start);
out(113:114)= newfl16(header.BIPCSRange.End);
out(115:116)= shorts2bytes(header.BIPCSRange.Step);
%7.2.24MCS field (Bytes 116 to 119)


%---------------------------------------
%%% encode_public_tag
function out = encode_public_tag(signature, public_tag, pcs, version)

lut_types = {'A2B0','A2B1','A2B2','B2A1','B2A2',...
    'gamt','pre0','pre1','pre2','A2B3','B2A0','B2A3'};
xyz_types = {'bkpt','bXYZ','gXYZ','lumi','rXYZ','wtpt'};
curve_types = {'bTRC','gTRC','kTRC','rTRC'};
text_desc_types = {'desc','dmdd','dmnd','scrd','vued'};
non_interpreted_types = {'bfd ','devs',...
    'psd0','psd1','psd2','psd3',...
    'ps2s','ps2i','scrn','dmdd','desc'};
text_types = {'targ'};
signature_Type={'ciis','rig0','rig2','tech'};
mulit_Process_Elements_Type = {'A2M0','bAB0','bAB1','bAB2','bAB3','bBA0',...
    'bAB1','bAB2','bAB3','bBA0','bBA1','bBA2','bBA3','bBD0','bBD1',...
    'bBD2','bBD3','bDB0','bDB1','bDB2','bDB3','B2D0','B2D1','B2D2',...
    'B2D3','c2sp','dAB0','dAB1','dAB2','dAB3','dBA0','dBA1','dBA2',...
    'dBA3','dBD0','dBD1','dBD2','dBD3','dDB0','dDB1','dDB2','dDB3',...
    'D2B0','D2B1','D2B2','D2B3','M2A0','M2B0','M2B1','M2B2','M2B3',...
    'M2S0','M2S1','M2S2','M2S3','s2cp'};
tag_Struuct_type={'bcp0','bcp1','bcp2','bcp3','bsp0','bsp1','bsp2',...
    'bsp3','bMB0','bMB1','bMB2','bMB3','bMS0','bMS1','bMS2','bMS3',...
    'cept','BRD3'};
utlf8_Type={'csnm','CxF','rfnm'};
% same as icc.1 colorant_Arder_Type = {'clro','cloo'};
tag_Array_Type={'clin','clio','psin','nmcl','mcta'};
gamut_Boundary_Description_Type={'gbd0','gbd1','gbd2','gbd3'};
measurementinfo_Type={'minf','miin'}; %with measurement Type
if version <= 2
    text_types = [text_types, {'cprt'}];
    non_interpreted_types = [non_interpreted_types, {'ncol'}];
else
    text_desc_types = [text_desc_types, {'cprt','dmdd','desc'}];
    %    non_interpreted_types = [non_interpreted_types, {'clrt'}];
end

% Handle any tags that couldn't be interpreted on input
if strcmp(class(public_tag), 'uint8')
    out = public_tag;
    return;
end

% Handle interpreted tags
switch char(signature)
  case lut_types
    % See Clauses 6.4.* (v. 2) and 9.2.* (v. 4.2)
    if public_tag.tagtype=='mpet'
        out=encode_mulit_Process_Elements_Type(public_tag);
    else
        if public_tag.MFT < 1    % for backwards compatibility
            out = encode_private_tag(public_tag.Data);
        else
            out = encode_lut_type(public_tag);
        end
    end

    
  case xyz_types
    % Clauses 6.4.* (v. 2) and 9.2.* (v. 4.2)
    out = encode_xyz_type(public_tag);
    
  case curve_types
    % Clauses 6.4.* (v. 2) and 9.2.* (v. 4.2)
    out = encode_curve_type(public_tag);
    
  case text_desc_types
    % Clauses 6.4.* (v. 2) and 9.2.* (v. 4.2)
    if version > 2
        out = encode_mluc(public_tag);
    else
        out = encode_text_description_type(public_tag);
    end
    
  case text_types
    % Clauses 6.4.* (v. 2) and 9.2.10 (v. 4.2)
    out = encode_text_type(public_tag);

  case non_interpreted_types    % treat as private tag
    % Clauses 6.4.* (v. 2)
    out = encode_private_tag(public_tag);
    
  case 'calt'
    % Clause 6.4.9 (v. 2) and 9.2.9 (v. 4.2)
    out = encode_date_time_type(public_tag);
    
  case 'chad'
    % Clause 6.4.11 (v. 2) and 9.2.11 (v. 4.2)
    out = encode_sf32_type(public_tag);
    
  case 'chrm'
    % Clause 9.2.12 (v. 4.2)
    out = encode_chromaticity_type(public_tag);
    
  case 'clro'
    % Clause 9.2.13 (v. 4.2)
    out = encode_colorant_order_type(public_tag);
    
  case {'clrt', 'clot'}
    % Clause 9.2.14 (v. 4.2)
    out = encode_colorant_table_type(public_tag, pcs);
        
  case 'crdi'
    % Clause 6.4.14 (v. 2) or 6.4.16 (v. 4.0)
    out = encode_crd_info_type(public_tag);
    
  case 'meas'
    % Clause 9.2.23 (v. 4.2)
    out = encode_measurement_type(public_tag);
    
  case 'ncl2'
    % Clause 9.2.26 (v. 4.2)
    if public_tag.tagtype=='tary'
        out=encode_tag_Array_Type(public_tag);
    else
    out = encode_named_color_type(public_tag, pcs);
    end
    
  case 'pseq'
    % Clause 9.2.32 (v. 4.2)
    out = encode_profile_sequence_type(public_tag, version);
    
  case 'resp'
    % Clause 9.2.27 (v. 4.2)
    out = encode_response_curve_set16_type(public_tag);
  case signature_Type
    out = encode_signature_type(public_tag);
  case measurementinfo_Type
        out = encode_measurementinfo_type(public_tag);
  case 'view'
    % viewingConditionsTag clause 6.4.47 (v. 2) or 9.2.37 (v. 4.2)
    out = encode_viewing_conditions(public_tag);
        case 'meta'
        out = encode_dict_Type(public_tag);
    case {'swpt','mdv','smwp'}
     %       out = encode_sparse_Matrix_Type(fid,offset,data_size,tagname);
            out = encode_Array_Type(public_tag);
    case gamut_Boundary_Description_Type
        out=encode_gamut_Boundary_Description_Type(public_tag);
    case 'svcn'
        out=encode_specral_Viewing_condition_Type(public_tag);
    case utlf8_Type
        out=encode_utlf8_Type(public_tag);
    case mulit_Process_Elements_Type
        out=encode_mulit_Process_Elements_Type(public_tag);
    case tag_Array_Type
        out=encode_tag_Array_Type(public_tag);
    case tag_Struuct_type
        out=encode_tag_Struct_type(public_tag);
    case 'smwi'
        out=encode_Spectral_data_Type(public_tag);
    otherwise
end
%------------------------------------------
%%% encode_private_tag
function out = encode_private_tag(tagdata)

out = uint8(tagdata);

%------------------------------------------
%%% encode_sf32_type
function out = encode_sf32_type(vals)

% Clause 6.5.14 (v. 2) or 10.18 (v. 4.2)
% 0-3  'sf32'
% 4-7  reserved, must be 0
% 8-n  array of s15Fixed16Number values

numvals = numel(vals);
data_size = numvals * 4 + 8;
out = uint8(zeros(1, data_size));
out(1:4) = uint8('sf32');
longs = int32(round(65536 * vals'));
out(9:data_size) = longs2bytes(longs);

%------------------------------------------
%%% encode_xyz_number
function out = encode_xyz_number(xyz)

% Clause 5.3.10 (v. 2) and 5.1.11 (v. 4.2)
% 0-3  CIE X    s15Fixed16Number
% 4-7  CIE Y    s15Fixed16Number
% 8-11 CIE Z    s15Fixed16Number

out = longs2bytes(int32(round(65536 * xyz)));

%------------------------------------------
%%% encode_xyz_type

function out = encode_xyz_type(xyzs)

% Clause 6.5.26 (v. 2) or 10.27 (v. 4.2)
% 0-3  'XYZ '
% 4-7  reserved, must be 0
% 8-n  array of XYZ numbers

numxyzs = size(xyzs, 1);
data_size = numxyzs * 3 * 4 + 8;
out = uint8(zeros(1, data_size));
out(1:4) = uint8('XYZ ');
longs = int32(round(65536 * xyzs'));
out(9:data_size) = longs2bytes(longs);

%------------------------------------------
%%% encode_chromaticity_type

function out = encode_chromaticity_type(chrm)

% Clause 10.2 (v. 4.2)
% 0-3    'chrm'
% 4-7    reserved, must be 0
% 8-9    number of device channels
% 10-11  encoded phosphor/colorant type
% 12-19  CIE xy coordinates of 1st channel
% 20-end CIE xy coordinates of remaining channels

numchan = size(chrm.xy, 1); % number of colorants
out = uint8(zeros(1, 12 + 8 * numchan));
out(1 : 4) = uint8('chrm');
out(9 : 10) = shorts2bytes(uint16(numchan));
out(11 : 12) = shorts2bytes(uint16(chrm.ColorantCode));

current = 12;
for i = 1 : numchan
    out(current + 1 : current + 4) = ...
        longs2bytes(uint32(round(65536.0 * chrm.xy(i, 1))));
    out(current + 5 : current + 8) = ...
        longs2bytes(uint32(round(65536.0 * chrm.xy(i, 2))));
    current = current + 8;
end

%------------------------------------------
%%% encode_colorant_order_type

function out = encode_colorant_order_type(clro)

% Clause 10.3 (v. 4.2)
% 0-3    'clro'
% 4-7    reserved, must be 0
% 8-11   number of colorants n
% 12     index of first colorant in laydown
% 13-end remaining (n - 1) indices, in laydown order

numchan = length(clro);
out = uint8(zeros(1, 12 + numchan));
out(1 : 4) = uint8('clro');
out(9 : 12) = longs2bytes(uint32(numchan));
for i = 1 : numchan
    out(12 + i) = uint8(clro(i));
end

%------------------------------------------
%%% encode_colorant_table_type

function out = encode_colorant_table_type(clrt, pcs)

% Clause 10.4 (v. 4.2)
% 0-3    'clrt'
% 4-7    reserved, must be 0
% 8-11   number of colorants n
% 12-43  name of first colorant, NULL terminated
% 44-49  PCS values of first colorant as uint16
% 50-end name and PCS values of remaining colorants

numchan = size(clrt, 1);
out = uint8(zeros(1, 12 + 38 * numchan));
out(1 : 4) = uint8('clrt');
out(9 : 12) = longs2bytes(uint32(numchan));

next = 13;
for i = 1 : numchan
  % Insert name, leaving space for at least one NULL at end
    lstring = min(length(clrt{i, 1}), 31);
    out(next : next + lstring - 1) = ...
                  uint8(clrt{i, 1}(1 : lstring));
              
    % Convert PCS coordinates to uint16 and insert
    pcs16 = encode_color(clrt{i, 2}, pcs, 'double', 'uint16');
    out(next + 32 : next + 37) = shorts2bytes(pcs16);
    next = next + 38;
end

%------------------------------------------
%%% encode_curve_type

function out = encode_curve_type(curve)

% Clause 6.5.3 (v. 2) or 10.5 (v. 4.2)
% 0-3    'curv'
% 4-7    reserved, must be 0
% 8-11   count value, uint32
% 12-end curve values, uint16

% For v. 4 can also be 'para'; see Clause 10.15 (v. 4.2)

if isnumeric(curve)                           % Encode curveType

    % Allocate space
    count = length(curve);
    if count == 1 && curve(1) == uint16(256)
        count = 0;      % gamma == 1, ==> identity
    end
    out = uint8(zeros(1, 2 * count + 12));

    % Insert signature and count
    out(1:4) = uint8('curv');
    out(9:12) = longs2bytes(uint32(count));

    % Encode curve data
    if count > 0
        out(13:end) = shorts2bytes(uint16(curve));
    end

elseif isstruct(curve) && isfield(curve, 'FunctionType') ...
        && isfield(curve, 'Params')  % Encode parametricCurveType
  
    % Allocate space
    out = uint8(zeros(1, 12 + 4 * length(curve.Params)));
    
    % Insert signature and function index
    out(1:4) = uint8('para');
    out(9:10) = shorts2bytes(uint16(curve.FunctionType));
    
    % Encode function parameters
    out(13:end) = longs2bytes(int32(round(65536 * curve.Params)));
    
else % error return
    out = [];
end

%------------------------------------------
%%% encode viewingConditionsType

function out = encode_viewing_conditions(conditions)

% Clause 6.5.25 (v. 2) or 10.26 (v. 4.2)
% 0-3 'view'
% 4-7 reserved, must be 0
% 8-19 absolute XYZ for illuminant in cd/m^2
% 20-31 absolute XYZ for surround in cd/m^2
% 32-35 illuminant type

illuminant_table = {'Unknown', 'D50', 'D65', 'D93', 'F2', ...
                    'D55', 'A', 'EquiPower', 'F8'};

out = uint8(zeros(1, 36));
out(1:4) = uint8('view');
out(9:20) = encode_xyz_number(conditions.IlluminantXYZ);
out(21:32) = encode_xyz_number(conditions.SurroundXYZ);
illum_idx = strmatch(conditions.IlluminantType, illuminant_table, 'exact');
out(33:36) = longs2bytes(uint32(illum_idx - 1));

%------------------------------------------
%%% encode_lut_type

function out = encode_lut_type(lut)

% Clauses 6.5.8 and 6.5.7 (v. 2) or 10.9 and 10.8 (v. 4.2)
% 0-3   'mft1', 'mft2'
% 4-7   reserved, must be 0
% 8     number of input channels, uint8
% 9     number of output channels, uint8
% 10    number of CLUT grid points, uint8
% 11    reserved for padding, must be 0
% 12-47 3-by-3 E matrix, stored row-major, each value s15Fixed16Number

% 16-bit LUT type ('mft2'):
% 48-49 number of input table entries, uint16
% 50-51 number of output table entries, uint16
% 52-n  input tables, uint16
%       CLUT values, uint16
%       output tables, uint16

% 8-bit LUT type ('mft1'):
% 48-   input tables, uint8
%       CLUT values, uint8
%       output tables, uint8

% New v. 4 LUT types, Clauses 10.10 and 10.11 (v. 4.2)
% 0-3   'mAB ', 'mBA '
% 4-7   reserved, must be 0
% 8     number of input channels, uint8
% 9     number of output channels, uint8
% 10-11 reserved for padding, must be 0
% 12-15 offset to first B-curve, uint32
% 16-19 offset to 3-by-4 matrix, uint32
% 20-23 offset to first M-curve, uint32
% 24-27 offset to CLUT values, uint32
% 28-31 offset to first A-curve, uint32
% 32-n  data:  curves stored as 'curv' or 'para' tags,
%              matrix stored as s15Fixed16Number[12],
%              CLUT stored as follows:
% 0-15  number of grid points in each dimension, uint8
% 16    precision in bytes (1 or 2), uint8
% 17-19 reserved for padding, must be 0
% 20-n  CLUT data points, uint8 or uint16

% Insert signature
if lut.MFT == 1
    out(1:4) = uint8('mft1');
elseif lut.MFT == 2
    out(1:4) = uint8('mft2');
elseif lut.MFT == 3
    out(1:4) = uint8('mAB ');
elseif lut.MFT == 4
    out(1:4) = uint8('mBA ');
else
    out = [];
    return;
end

% Insert reserved padding bytes
out(5:8) = uint8(zeros(1, 4));

% Determine input-output connectivity
[num_input_channels, num_output_channels] = luttagchans(lut);

if lut.MFT < 3 % older lut types
  % Determine lut dimensions and allocate space
    for i = 1 : num_input_channels
        itbl(:, i) = lut.InputTables{i}; %#ok<AGROW>
    end
    num_input_table_entries = size(itbl, 1);
    for i = 1 : num_output_channels
        otbl(:, i) = lut.OutputTables{i}; %#ok<AGROW>
    end
    num_output_table_entries = size(otbl, 1);
    num_clut_grid_points = size(lut.CLUT, 1);
    ndims_clut = num_output_channels;
    clut_size = ones(1, num_input_channels) * num_clut_grid_points;
    num_clut_elements = prod(clut_size);

    nbytesInput = num_input_table_entries * num_input_channels * lut.MFT;
    nbytesOutput = num_output_table_entries * num_output_channels * lut.MFT;
    nbytesCLUT = num_clut_elements * ndims_clut * lut.MFT;
    nbytes = 48 + nbytesInput + nbytesOutput + nbytesCLUT;
    if lut.MFT == 2
       nbytes = nbytes + 4;     % variable table sizes
    end
    
    out(9:nbytes) = uint8(zeros(1, nbytes - 8));

  % Insert table dimensions
    out(9) = uint8(num_input_channels);
    out(10) = uint8(num_output_channels);
    out(11) = uint8(num_clut_grid_points);

  % Insert matrix
    out(13:48) = ...
        longs2bytes(int32(round ...
                     (65536 * reshape(lut.PreMatrix(1:3, 1:3)', 1, 9))));

  % Insert lut contents
    itbl = reshape(itbl, 1, num_input_channels * num_input_table_entries);
    otbl = reshape(otbl, 1, num_output_channels * num_output_table_entries);
    clut = reshape(lut.CLUT, num_clut_elements, ndims_clut)';
    clut = reshape(clut, 1, ndims_clut * num_clut_elements);
    switch lut.MFT 
        case 2 % Means 16-bit CLUT
            out(49:50) = shorts2bytes(uint16(num_input_table_entries));
            out(51:52) = shorts2bytes(uint16(num_output_table_entries));
            out(53:(52 + nbytesInput)) = shorts2bytes(uint16(itbl));
            out((53 + nbytesInput):(52 + nbytesInput + nbytesCLUT)) = ...
                  shorts2bytes(uint16(clut));
            out((53 + nbytesInput + nbytesCLUT):(52 + nbytesInput + nbytesCLUT + nbytesOutput)) = ...
                  shorts2bytes(uint16(otbl));

        case 1 % Means 8-bit CLUT
            out(49:(48 + nbytesInput)) = uint8(itbl);
            out((49 + nbytesInput):(48 + nbytesInput + nbytesCLUT)) = uint8(clut);
            out((49 + nbytesInput + nbytesCLUT):(48 + nbytesInput + nbytesCLUT + nbytesOutput)) = ...
                  uint8(otbl);

    end
else % new v. 4 lut types
    out(9) = uint8(num_input_channels);
    out(10) = uint8(num_output_channels);
    out(11:12) = uint8(zeros(1, 2));     % required padding
    out(13:32) = uint8(zeros(1, 20));    % leave space for offsets
    
  % Identify storage elements   
    if lut.MFT == 3 % lutAtoBType
        Acurve = lut.InputTables;
        ndlut = lut.CLUT;
        Mcurve = lut.OutputTables;
        PMatrix = lut.PostMatrix;
        Bcurve = lut.PostShaper;
    elseif lut.MFT == 4 % lutBtoAType
        Bcurve = lut.PreShaper;
        PMatrix = lut.PreMatrix;
        Mcurve = lut.InputTables;
        ndlut = lut.CLUT;
        Acurve = lut.OutputTables;
    end

  % Store B-curves (required)
    if isempty(Bcurve)
        out = [];
        return;
    else
        boffset = 32;
        current = boffset;
        numchan = size(Bcurve, 2);
        for i = 1 : numchan
            curve = encode_curve_type(Bcurve{i});
            curve = bump(curve);
            out = [out, curve]; %#ok<AGROW>
            current = current + length(curve);
        end
    end
    
  % Store PCS-side matrix (optional)
    if isempty(PMatrix)
        xoffset = 0;
    else
        xoffset = current;
        mat3by3 = PMatrix(1:3, 1:3);
        out(current + 1 : current + 9 * 4) = longs2bytes(int32(round(mat3by3' * 65536)));
        current = current + 9 * 4;
        out(current + 1 : current + 3 * 4) = longs2bytes(int32(round(PMatrix(:, 4)' * 65536)));
        current = current + 3 * 4;
    end
    
  % Store M-curves (optional)
    if isempty(Mcurve)
        moffset = 0;
    else
        moffset = current;
        numchan = size(Mcurve, 2);
        for i = 1 : numchan
            curve = encode_curve_type(Mcurve{i});
            curve = bump(curve);
            out = [out, curve]; %#ok<AGROW>
            current = current + length(curve);
        end
    end
    
  % Store n-dimensional LUT (optional)
    if isempty(ndlut)
        coffset = 0;
    else
        coffset = current;
        
      % Store grid dimensions
        size_ndlut = size(ndlut);
        clut_size = size_ndlut(1, 1 : num_input_channels);
        for i = 1 : num_input_channels
            out(current + i) = uint8(clut_size(num_input_channels + 1 - i));
        end % reverse order of dimensions for ICC spec
        for i = num_input_channels + 1 : 16 % unused channel dimensions
            out(current + i) = uint8(0);
        end
        current = current + 16;
        
      % Store data size (in bytes) and add padding
        if isa(ndlut, 'uint8')
            datasize = 1;
        else % 'uint16'
            datasize = 2;
        end
        out(current + 1) = uint8(datasize);
        out(current + 2 : current + 4) = uint8(zeros(1, 3));
        current = current + 4;

      % Store multidimensional table
        num_clut_elements = prod(clut_size);
        ndims_clut = num_output_channels;
        ndlut = reshape(ndlut, num_clut_elements, ndims_clut);
        ndlut = ndlut';
        ndlut = reshape(ndlut, 1, num_clut_elements * ndims_clut);
        if datasize == 1
            luttag = uint8(ndlut);
        else
            luttag = shorts2bytes(uint16(ndlut));
        end
        luttag = bump(luttag);
        out = [out, luttag];
        current = current + length(luttag);
    end
    
  % Store A-curves (optional)
    if isempty(Acurve)
        aoffset = 0;
    else
        aoffset = current;
        numchan = size(Acurve, 2);
        for i = 1 : numchan
            curve = encode_curve_type(Acurve{i});
            curve = bump(curve);
            out = [out, curve]; %#ok<AGROW>
            current = current + length(curve);
        end
    end
    
  % Store offsets
    out(13:16) = longs2bytes(uint32(boffset));
    out(17:20) = longs2bytes(uint32(xoffset));
    out(21:24) = longs2bytes(uint32(moffset));
    out(25:28) = longs2bytes(uint32(coffset));
    out(29:32) = longs2bytes(uint32(aoffset));

end

%------------------------------------------
%%% encode_measurement_type

function out = encode_measurement_type(meas)

% Clause 10.12 (v. 4.2)
% 0-3    'meas'
% 4-7    reserved, must be 0
% 8-11   encoded standard observer
% 12-23  XYZ of measurement backing
% 24-27  encoded measurement geometry
% 28-31  encoded measurement flare
% 32-35  encoded standard illuminant

out = zeros(1, 36);
out(1 : 4) = uint8('meas');
out(9 : 12) = longs2bytes(uint16(meas.ObserverCode));
out(13 : 24) = encode_xyz_number(meas.MeasurementBacking);
out(25 : 28) = longs2bytes(uint16(meas.GeometryCode));
out(29 : 32) = longs2bytes(uint16(meas.FlareCode));
out(33 : 36) = longs2bytes(uint16(meas.IlluminantCode));

%------------------------------------------
%%% encode_named_color_type

function out = encode_named_color_type(named, pcs)

% Clause 10.14 (v. 4.2)
% 0-3     'ncl2'  (namedColor2Type signature)
% 4-7     reserved, must be 0
% 8-11    vendor-specific flag
% 12-15   count of named colours (n)
% 16-19   number m of device coordinates
% 20-51   prefix (including NULL terminator)
% 52-83   suffix (including NULL terminator)
% 84-115  first colour name (including NULL terminator)
% 116-121 first colour's PCS coordinates
% 122-(121 + 2m) first colour's device coordinates
% . . .   and so on for remaining (n - 1) colours

n = size(named.NameTable, 1);
m = named.DeviceCoordinates;
out = zeros(1, 84 + n * (38 + 2 * m));

out(1:4) = uint8('ncl2');
out(9:12) = longs2bytes(uint32(hex2dec(named.VendorFlag)));
out(13:16) = longs2bytes(uint32(n));
out(17:20) = longs2bytes(uint32(m));
lstring = min(length(named.Prefix), 31); % leave space for NULL
out(21 : 20 + lstring) = uint8(named.Prefix(1:lstring));
lstring = min(length(named.Suffix), 31);
out(53 : 52 + lstring) = uint8(named.Suffix(1:lstring));

next = 85;
for i = 1 : n
    % Insert name, leaving space for at least one NULL at end
    lstring = min(length(named.NameTable{i, 1}), 31);
    out(next : next + lstring - 1) = ...
                  uint8(named.NameTable{i, 1}(1 : lstring));
              
    % Convert PCS coordinates to uint16 and insert
    pcs16 = encode_color(named.NameTable{i, 2}, pcs, ...
                       'double', 'uint16');
    out(next + 32 : next + 37) = shorts2bytes(pcs16);
    
    % Convert any device coordinates to uint16 and insert
    if size(named.NameTable, 2) > 2
        device16 = encode_color(named.NameTable{i, 3}, 'color_n', ...
                                'double', 'uint16');
        out(next + 38 : next + 37 + 2 * m) = shorts2bytes(device16);
    end
    next = next + 38 + 2 * m;
end

%------------------------------------------
%%% encode_profile_sequence_type

function out = encode_profile_sequence_type(seq, version)

% Clause 10.16 (v. 4.2)
% 0-3   'pseq'
% 4-7   reserved, must be 0
% 8-11  count of profile description structures
% 12-   profile description structures

% Initialize output array with signature and count
out = uint8(zeros(1, 12));
out(1:4) = uint8('pseq');
n = length(seq);
out(9:12) = longs2bytes(uint32(n));

% Append profile description structures
technologies = get_technologies;
for p = 1:n
    pdesc(1:4) = uint8(seq(p).DeviceManufacturer);
    pdesc(5:8) = uint8(seq(p).DeviceModel);
    pdesc(9:12) = uint8(zeros(1, 4));
    pdesc(13:16) = longs2bytes(seq(p).Attributes);
    if strcmp(seq(p).Technology, 'Unspecified')
        pdesc(17:20) = uint8(zeros(1, 4));
    else
        idx = strmatch(seq(p).Technology, technologies(:, 2));
        if isempty(idx)
            pdesc(17:20) = uint8(zeros(1, 4));
        else
            pdesc(17:20) = uint8(technologies{idx, 1});
        end
    end
    out = [out, pdesc]; %#ok<AGROW>
    
    if version <= 2
        if strcmp(seq(p).DeviceMfgDesc.String, 'Unavailable')
            blank.String = '';
            blank.Optional = uint8(zeros(1, 78));
            dmnd = encode_text_description_type(blank);
        else
            dmnd = encode_text_description_type(seq(p).DeviceMfgDesc);
        end
    else
        if strcmp(seq(p).DeviceMfgDesc.String, 'Unavailable')
            seq(p).DeviceMfgDesc.String = '';
        end
        dmnd = encode_mluc(seq(p).DeviceMfgDesc);
    end
    out = [out, dmnd]; %#ok<AGROW>
    
    if version <= 2
        if strcmp(seq(p).DeviceModelDesc.String, 'Unavailable')
            blank.String = '';
            blank.Optional = uint8(zeros(1, 78));
            dmdd = encode_text_description_type(blank);
        else
            dmdd = encode_text_description_type(seq(p).DeviceModelDesc);
        end
    else
        if strcmp(seq(p).DeviceModelDesc.String, 'Unavailable')
            seq(p).DeviceModelDesc.String = '';
        end
        dmdd = encode_mluc(seq(p).DeviceModelDesc);
    end
    out = [out, dmdd]; %#ok<AGROW>
end

%------------------------------------------
%%% encode_response_curve_set16_type

function out = encode_response_curve_set16_type(rcs2)

% Clause 10.17 (v. 4.2)
% 0-3    'rcs2'
% 4-7    reserved, must be 0
% 8-9    number of channels n
% 10-11  number of measurement types m
% 12-(11+4m)    array of offsets
% (12+4m)-end   m response-curve structures

numtypes = length(rcs2); % 1D structure array
numchan = size(rcs2(1).SolidXYZs, 1);

out = uint8(zeros(1, 12 + 4 * numtypes)); 
out(1 : 4) = uint8('rcs2');
out(9 : 10) = shorts2bytes(uint16(numchan));
out(11 : 12) = shorts2bytes(uint16(numtypes));
current = 12 + 4 * numtypes; % start of response-curve structures

% response-curve structure
% 0-3             measurement-type signature
% 4-(3+4n)        number of measurements for each channel
% (4+4n)-(3+16n)  XYZ of solid-colorant patches
% (4+16n)-end     n response arrays

for i = 1 : numtypes
    out(9 + 4 * i : 12 + 4 * i) = longs2bytes(uint16(current));
    out(current + 1 : current + 4) = uint8(rcs2(i).MeasurementCode);
    current = current + 4;
    nmeas = zeros(1, numchan);
    for j = 1 : numchan
        nmeas(j) = size(rcs2(i).ResponseArray{j}, 1);
        out(current + 1 : current + 4) = longs2bytes(uint32(nmeas(j)));
        current = current + 4;
    end
    for j = 1 : numchan
        out(current + 1 : current + 12) = ...
            encode_xyz_number(rcs2(i).SolidXYZs(j, :));
        current = current + 12;
    end
    for j = 1 : numchan
        responsearray = [];
        for k = 1 : nmeas(j)
            devcode = 65535.0 * rcs2(i).ResponseArray{j}(k, 1);
            measure = 65536.0 * rcs2(i).ResponseArray{j}(k, 2);
            response(1 : 2) = shorts2bytes(uint16(round(devcode)));
            response(5 : 8) = longs2bytes(uint32(round(measure)));
            responsearray = [responsearray response]; %#ok<AGROW>
        end
        out(current + 1 : current + 8 * nmeas(j)) = responsearray;
        current = current + 8 * nmeas(j);
    end
end
    
%------------------------------------------
%%% encode_signature_type

function out = encode_signature_type(technology)

% Clause 10.19 (v. 4.2)
% 0-3   'sig '
% 4-7   reserved, must be 0
% 8-11  four-byte signature

out = uint8(zeros(1, 12));
out(1:4) = uint8('sig ');
if ~strcmp(technology, 'Unspecified')
    technologies = get_technologies;
    idx = strmatch(technology, technologies(:, 2));
    if isempty(idx)
        return;
    else
       out(9:12) = uint8(technologies{idx, 1});
    end
end
    
%------------------------------------------
%%% encode_text_description_type

function out = encode_text_description_type(description)

% Clause 6.5.17 (v. 2 only)
% 0-3          'desc'
% 4-7          reserved, must be 0
% 8-11         ASCII invariant description count, with terminating NULL
% 12-(n-1)     ASCII invariant description
% followed by optional Unicode and ScriptCode descriptions, which we
% replace with new text if the ASCII description has changed.
% n-(n+3)      Unicode language code (uint32)
% (n+4)-(n+7)  Unicode description count with NULL (uint32)
% (n+8)-(m-1)  Unicode description (2 bytes per character)
% m-(m+1)      ScriptCode code (uint16)
% m+2          ScriptCode description count with NULL (uint8)
% (m+3)-(m+69) ScriptCode description
% Note:  Unicode code and count are always required, as are
%        ScriptCode code, count, and description.  These can
%        all be zeros, but they consume at least 78 bytes even
%        if no textual information is encoded.

% Handle v. 2 type interpreted by older iccread
if ~isfield(description, 'Plain') &&  ~isfield(description, 'String')
    description.String = description;
    description.Optional = uint8(zeros(1, 78));
         % minimal data (no Unicode or ScriptCode)
end
if isfield(description, 'Plain')
    description.String = description.Plain;
end
if ~isfield(description, 'Optional')
    description.Optional = uint8(zeros(1, 78));
end

% Allocate minimal space
asciicount = length(description.String) + 1;
optionalcount = length(description.Optional);
out = uint8(zeros(1, 12 + asciicount + 78));

% Insert signature and ASCII character count
out(1:4) = uint8('desc');
out(9:12) = longs2bytes(uint32(asciicount));

% Insert ASCII text description, with terminating NULL
newstring = description.String;
newstring(asciicount) = char(uint8(0)); % add null terminator
out(13:(12 + asciicount)) = uint8(newstring);

% Adjust Unicode & ScriptCode description, if any, to agree 
% with ASCII string, which may have been modified
unicount = double(description.Optional(5 : 8));
unilength = bitshift(unicount(1), 24) + bitshift(unicount(2), 16) + ...
            bitshift(unicount(3), 8) + unicount(4);

scriptsection = description.Optional(9 + 2 * unilength : end);
% ScriptCode section is always 70 bytes.  The first 3 are
% reserved for code and count, leaving 67 for the string.
% But some v. 2 profiles violate this rule, so we must make
% allowances. The output profile will conform to the rule.
sclength = length(scriptsection);
if sclength < 70
    scriptsection(sclength + 1 : 70) = uint8(zeros(1, 70 - sclength));
    optionalcount = optionalcount + 70 - sclength;
end

scriptlength = double(scriptsection(3)); % actual string length
scripttext = scriptsection(4 : 3 + scriptlength);

% Replace any existing Unicode if it doesn't match ASCII String
if unilength > 0 % there is a Unicode string
    % Compare with ASCII String
    unistring = native2unicode(description.Optional(9 : (8 + 2 * unilength)), ...
                               'utf-16be');
    unistart = strfind(unistring, description.String); % skip leading characters
    if ~isempty(unistart)
        match = strcmp(unistring(unistart : end), description.String);
    else
        match = false;
    end
    if ~match
        % Replace with new Unicode string, keeping original FEFF
        % or other special character at beginning
        newunistring = unicode2native(newstring, 'utf-16be');
        if description.Optional(9) ~= 0   % special character
            description.Optional(5 : 8) = longs2bytes(uint32(asciicount + 1));
            description.Optional(11 : 10 + 2 * asciicount) = newunistring;
            optionalcount = 80 + 2 * asciicount;
        else   % presumably, no leading special character
            description.Optional(5 : 8) = longs2bytes(uint32(asciicount));
            description.Optional(9 : 8 + 2 * asciicount) = newunistring;
            optionalcount = 78 + 2 * asciicount;
        end
    end
end

% Replace any existing ScriptCode if it doesn't match ASCII String
if scriptlength > 0 % there is a ScriptCode string
    % Compare with ASCII
    scriptstart = strfind(scripttext, newstring);
    if isempty(scriptstart) % it doesn't match
       
        % Replace ScriptCode, if it fits
        if asciicount < 68
            scriptsection(3) = uint8(asciicount);
            scriptsection(4 : 3 + asciicount) = uint8(newstring);
            scriptsection(4 + asciicount : 70) = ...
                                  uint8(zeros(1, 67 - asciicount));
        end
    end
end

% Whether replaced or not, reinsert ScriptCode into Optional after
% Unicode (which may have changed) 
description.Optional(optionalcount - 69 : optionalcount) = ...
                                              scriptsection(1 : 70);
                                          
% Insert optional Unicode and ScriptCode data into output array
out((12 + asciicount + 1):(12 + asciicount + optionalcount)) ...
          = uint8(description.Optional(1 : optionalcount));

%------------------------------------------
function out = encode_mluc(description)

% Clause 10.13 (v. 4.2)
% 0-3   'mluc'
% 4-7   reserved, must be 0
% 8-11  number of name records that follow (n)
% 12-15 name-record length (currently 12)
% 16-17 first-name language code (ISO-639)
% 18-19 first-name country code (ISO-3166)
% 20-23 first-name length
% 24-27 first-name offset
% 28-(28+12n)         [n should be (n - 1) - rfp]
%       additional name records, if any
% (28+12n)-end        [n should be (n - 1) - rfp]
%       Unicode characters (2 bytes each)

% Allocate space in output array and initialize to zero
first_unicode_character_offset = 16 + 12*numel(description);
nbytes = first_unicode_character_offset;
for k = 1 : numel(description)
    nbytes = nbytes + 2 * numel(description(k).String);
end % Two bytes per Unicode character in each string
out = uint8(zeros(1, nbytes));

% Insert signature, number of records, and record length
out(1:4) = uint8('mluc');
out(9:12) = longs2bytes(uint32(numel(description)));
out(13:16) = longs2bytes(uint32(12));

% Insert "name" records
total_unicode_bytes = 0;
current = 16;
for k = 1:numel(description)
    out(current + 1 : current + 2) =uint16(description(k).LanguageCode);
        % shorts2bytes(uint16(description(k).LanguageCode));
    out(current + 3 : current + 4) = uint16(description(k).CountryCode);
        % shorts2bytes(uint16(description(k).CountryCode));
    num_bytes = 2 * numel(description(k).String);
    out(current + 5 : current + 8) = longs2bytes(uint32(num_bytes));
    out(current + 9 : current + 12) = ...
        longs2bytes(uint32(first_unicode_character_offset + total_unicode_bytes));
    total_unicode_bytes = total_unicode_bytes + num_bytes;
    current = current + 12;
end

% Insert "names" in Unicode
for k = 1:numel(description)
    unibytes = unicode2native(description(k).String, 'utf-16be');
    lengthk = length(unibytes);
    out(current + 1 : current + lengthk) = unibytes;
    current = current + lengthk;
end

%------------------------------------------
%%% encode_text_type

function out = encode_text_type(textstring)

% Clause 6.5.18 (v. 2) or 10.20 (v. 4.2)
% 0-3 'text'
% 4-7 reserved, must be 0
% 8-  string of (data_size - 8) 7-bit ASCII characters, including NULL

out = uint8(zeros(1, length(textstring) + 9));
out(1:4) = uint8('text');
if isa(textstring,'struct')
    out(9:(8 + length(textstring.String))) = uint8(textstring.String);
    out(9 + length(textstring.String)) = uint8(0);
else
    out(9:(8 + length(textstring))) = uint8(textstring);
    out(9 + length(textstring)) = uint8(0);
end    % Unnecessary, but explicit

%------------------------------------------
%%% encode_date_time_type

function out = encode_date_time_type(dtnumber)

% Clause 6.5.5 (v. 2) or 10.7 (v. 4.2)
% 0-3   'dtim'
% 4-7   reserved, must be 0
% 8-19  DateTimeNumber

% Verify that dtnumber is an array of six 16-bit integers

out = uint8(zeros(1, 20));
out(1:4) = uint8('dtim');
out(9:20) = encode_date_time_number(dtnumber);

%------------------------------------------
%%% encode_crd_info_type

function out = encode_crd_info_type(crd_info)

% Clause 6.5.2 (v. 2) or 6.5.4 (v. 4.0)
% 0-3   'crdi'
% 4-7   reserved, must be 0
% 8-11  PostScript product name character count, uint32
%       PostScript product name, 7-bit ASCII
%       Rendering intent 0 CRD name character count, uint32
%       Rendering intent 0 CRD name, 7-bit ASCII
%       Rendering intent 1 CRD name character count, uint32
%       Rendering intent 1 CRD name, 7-bit ASCII
%       Rendering intent 2 CRD name character count, uint32
%       Rendering intent 2 CRD name, 7-bit ASCII
%       Rendering intent 3 CRD name character count, uint32
%       Rendering intent 3 CRD name, 7-bit ASCII

% Verify that psproductname is a string and that crdnames is
% a cell array of strings, of length 4.
psproductname = crd_info.PostScriptProductName;
crdnames = crd_info.RenderingIntentCRDNames;

% Allocate space required, including NULL terminators
lenp = length(psproductname) + 1;
lencrd = zeros(1, 4);
for k = 1:4
    lencrd(k) = length(crdnames{k}) + 1;
end
out = uint8(zeros(1, 28 + lenp + sum(lencrd)));

% Insert signature, lengths, and names
out(1:4) = uint8('crdi');
last = 8;     % 4 bytes reserved (= 0)
out((last + 1):(last + 4)) = longs2bytes(uint32(lenp));
last = last + 4;
out((last + 1):(last + lenp - 1)) = uint8(psproductname);
out(last + lenp) = uint8(0);
last = last + lenp;
for k = 1:4
    out((last + 1):(last + 4)) = longs2bytes(uint32(lencrd(k)));
    last = last + 4;
    out((last + 1):(last + lencrd(k) - 1)) = uint8(crdnames{k});
    out(last + lencrd(k)) = uint8(0);
    last = last + lencrd(k);
end

%------------------------------------------
%%% encode_date_time_number

function out = encode_date_time_number(dtn)

% Clause 5.3.1 (v. 2) and 5.1.1 (v. 4.2)
out = shorts2bytes(uint16(dtn));

%------------------------------------------
%%% bump -- add zeros to byte array to reach
%           next 32-bit boundary

function tag = bump(tag)

padding = mod(-length(tag), 4);
if padding ~= 0
    tag = [tag, uint8(zeros(1, padding))];
end

%------------------------------------------
%%% shorts2bytes

function bytes = shorts2bytes(shorts)

% Convert signed to unsigned
if isa(shorts, 'int16')
    ushorts = uint16(zeros(size(shorts)));
    negs = find(shorts < 0);
    nonnegs = find(shorts >= 0);
    two16 = double(intmax('uint16')) + 1.0;
    base16 = ones(size(shorts)) * two16;
    ushorts(nonnegs) = uint16(shorts(nonnegs));
    ushorts(negs) = uint16(double(shorts(negs)) + base16(negs));
    shorts = ushorts;
end

numshorts = numel(shorts);
shorts = reshape(shorts, 1, numshorts);
bytes = uint8(zeros(2, numshorts));
bytes(1, :) = uint8(bitshift(shorts, -8));
bytes(2, :) = uint8(bitand(shorts, 255));
bytes = reshape(bytes, 1, 2 * numshorts);

%------------------------------------------
%%% longs2bytes

function bytes = longs2bytes(longs)

% Convert signed to unsigned
if isa(longs, 'int32')
    ulongs = uint32(zeros(size(longs)));
    negs = find(longs < 0);
    nonnegs = find(longs >= 0);
    two32 = double(intmax('uint32')) + 1.0;
    base32 = ones(size(longs)) * two32;
    ulongs(nonnegs) = uint32(longs(nonnegs));
    ulongs(negs) = uint32(double(longs(negs)) + base32(negs));
    longs = ulongs;
end

numlongs = numel(longs);
longs = reshape(longs, 1, numlongs);
bytes = uint8(zeros(4, numlongs));
bytes(1, :) = uint8(bitshift(longs, -24));
bytes(2, :) = uint8(bitand(bitshift(longs, -16), 255));
bytes(3, :) = uint8(bitand(bitshift(longs, -8), 255));
bytes(4, :) = uint8(bitand(longs, 255));
bytes = reshape(bytes, 1, 4 * numlongs);

%------------------------------------------
%%% fwrite_check

function fwrite_check(fid, a, precision)

count = fwrite(fid, a, precision);
if count ~= numel(a)
    pos = ftell(fid) - count;
    fclose(fid);
    error(message('images:iccwrite:fileWriteFailed', n, pos))
end

function out = encode_measurementinfo_type(public)
out = zeros(1, 40);
out(1 : 4) = uint8('meas');
out(9 : 12) = longs2bytes(uint16(public.ObserverCode));
out(13 : 24) = encode_xyz_number(public.MeasurementBacking);
out(25 : 28) = longs2bytes(uint16(public.GeometryCode));
out(29 : 32) = longs2bytes(uint16(public.FlareCode));
out(33 : 36) = longs2bytes(uint16(public.IlluminantCode));
out(37 : 40) = longs2bytes(uint16(public.ConditionCode));

function out = encode_dict_Type(public_tag)
out=zeros(1,public_tag.size);
out(1:4)=uint8('dict');
out(9:12)=longs2bytes(public_tag.M);
out(13:16)=longs2bytes(public_tag.N);
for i=1:public_tag.M
    a=size(public_tag.NAme_Value.name);
    a=a(1,2);
    b=size(public_tag.NAme_Value.value);
    b=b(1,2);
    switch public_tag.N
        case 16
            c=double(public_tag.NAme_Value.name);
            d=double(public_tag.NAme_Value.value);
            j=[c,d];
            e=size(j);e=e(1,2);
            g=zeros(1,2*e);
            for h=1:e
                g(1,2*h)=j(1,h);
            end
            out(17+public_tag.M*16:16+public_tag.M*16+2*e)=g;
        case 24
        case 32
        otherwise  
    end
     out(13+i*4:16+i*4)=longs2bytes(16+16*public_tag.M);
     out(17+i*4:20+i*4)=longs2bytes(2*a);
     out(21+i*4:24+i*4)=longs2bytes(16+16*public_tag.M+2*a);
     out(25+i*4:28+i*4)=longs2bytes(2*b);
end
function out = encode_Array_Type(public_tag)
switch public_tag.tagtype
    case 'fl16'
        a=size(public_tag.array);
        a=a(1,1);
        out=zeros(1,8+2*a);
        out(1:4)=uint8('fl16');
        for b=1:a
            out(7+2*b:8+2*b)=newfl16(public_tag.array(b,1)); 
        end
    case 'fl32'
        a=size(public_tag.array);
        a=a(1,1);
        out=zeros(1,8+4*a);
        out(1:4)=uint8('fl32');
        out(9:8+4*a)=longs2bytes(uint16(public_tag.array)');        
    case 'fl64'
    case 'ui16'
        a=size(public_tag.array);
        a=a(1,1);
        out=zeros(1,8+2*a);
        out(1:4)=uint8('ui16');
        for b=1:a
            out(7+2*b:8+2*b)=shorts2bytes(public_tag.array(b,1));
        end
    otherwise
end
function out=encode_gamut_Boundary_Description_Type(public_tag)
% 默认 三输入四输出
out=zeros(1,20+public_tag.F*12+public_tag.V*4*(public_tag.input+public_tag.output));
out(1:4)=uint8('gbd ');
out(9:10)=shorts2bytes(public_tag.input);
out(11:12)=shorts2bytes(public_tag.output);
out(13:16)=longs2bytes(public_tag.V);
out(17:20)=longs2bytes(public_tag.F);
out(21:public_tag.size)=public_tag.data';
function out=encode_specral_Viewing_condition_Type(public_tag)
% out=zeros(1,public_tag.size);
size_N=size(public_tag.XYZ);
N=size_N(1,1);
size_M=size(public_tag.Vector_illuminant);
M=size_M(1,1);
out=zeros(1,60+(M+N)*4);
out(1:4)=uint8('svcn');
switch public_tag.Colorimetric_observer_type
    case 'Custom'
        out(9:12)=[0,0,0,0];
    case 'CIE 1931'
        out(9:12)=[0,0,0,1];
    case 'CIE 1964'
        out(9:12)=[0,0,0,2];
    otherwise
        out(9:12)=[0,0,0,3];
end
out(13:14)=newfl16(public_tag.SpectralPCSRange.Start);
out(15:16)=newfl16(public_tag.SpectralPCSRange.End);
out(17:18)=shorts2bytes(public_tag.SpectralPCSRange.Step);
% 19~20是0
b=public_tag.SpectralPCSRange.Step;
for a=1:3*b
    out(17+4*a:20+4*a)=newfloat(public_tag.XYZ(a,1));
end
switch public_tag.StandardIlluminant
    case 'D50'
        out(21+4*a:24+4*a)=[0,0,0,1];
    case  'D65'
        out(21+4*a:24+4*a)=[0,0,0,2];
    case  'D93'
        out(21+4*a:24+4*a)=[0,0,0,3];
    case  'F2'
        out(21+4*a:24+4*a)=[0,0,0,4];
    case  'D55'
        out(21+4*a:24+4*a)=[0,0,0,5];
    case  'A'
        out(21+4*a:24+4*a)=[0,0,0,6];
    case 'E'
        out(21+4*a:24+4*a)=[0,0,0,7];
    case  'F8'
        out(21+4*a:24+4*a)=[0,0,0,8];
    case  'Black body'
        out(21+12*a:25+12*a)=[0,0,0,9];
    case  'Daylight'
        out(21+4*a:24+4*a)=[0,0,0,10];
    case  'B'
        out(21+4*a:24+4*a)=[0,0,0,11];
    case  'C'
        out(21+4*a:24+4*a)=[0,0,0,12];
    case  'F1'
       out(21+4*a:24+4*a)=[0,0,0,13];
    case  'F3'
        out(21+4*a:24+4*a)=[0,0,0,14];
    case  'F4'
        out(21+4*a:24+4*a)=[0,0,0,15];
    case  'F5'
        out(21+4*a:24+4*a)=[0,0,0,16];
    case  'F6'
        out(21+4*a:24+4*a)=[0,0,0,17];
    case  'F7'
        out(21+4*a:24+4*a)=[0,0,0,18];
    case  'F9'
        out(21+4*a:24+4*a)=[0,0,0,19];
    case  'F10'
       out(21+4*a:24+4*a)=[0,0,0,20];
    case  'F11'
        out(21+4*a:24+4*a)=[0,0,0,21];
    case  'F12'
        out(21+4*a:24+4*a)=[0,0,0,22];
    otherwise
        out(21+4*a:24+4*a)=[0,0,0,0];
end
out(25+4*a:28+4*a)=newfloat(public_tag.temperature);
out(29+4*a:30+4*a)=newfl16(public_tag.Spectral_range.Start);
out(31+4*a:32+4*a)=newfl16(public_tag.Spectral_range.End);
out(33+4*a:34+4*a)=shorts2bytes(public_tag.Spectral_range.Step);
c=public_tag.Spectral_range.Step;
for b=1:c
    out(33+4*a+4*b:36+4*a+4*b)=newfloat(public_tag.Vector_illuminant(b,1));
end
% encode_xyz_number
out(37+4*a+4*b:40+4*a+4*b)=newfloat(public_tag.values_for_illuminant(1,1));
out(41+4*a+4*b:44+4*a+4*b)=newfloat(public_tag.values_for_illuminant(2,1));
out(45+4*a+4*b:48+4*a+4*b)=newfloat(public_tag.values_for_illuminant(3,1));
out(49+4*a+4*b:52+4*a+4*b)=newfloat(public_tag.values_for_surround(1,1));
out(53+4*a+4*b:56+4*a+4*b)=newfloat(public_tag.values_for_surround(2,1));
out(57+4*a+4*b:60+4*a+4*b)=newfloat(public_tag.values_for_surround(3,1));
function out=encode_utlf8_Type(public_tag)
out=zeros(1,public_tag.size);
switch public_tag.tagtype
    case 'utf8'
        out(1:4)=uint8('utf8');
        out(9:public_tag.size)=unicode2native(public_tag.sig,'UTF-8');
    case 'ut16'
        out(1:4)=uint8('ut16');
         out(9:public_tag.size)=unicode2native(public_tag.sig,'utf-16be');
    case 'ZXML'
        out(1:4)=uint8('ZXML');   
        out(9:public_tag.size)=uint8(public_tag.CM);
    otherwise
end
function out=encode_tag_Array_Type(public_tag)
out=zeros(1,public_tag.size);
out(1:4)=uint8('tary');
out(9:12)=uint8(public_tag.IDen);
out(13:16)=longs2bytes(public_tag.N);
c=zeros(1,public_tag.size-16-8*public_tag.N);
f=0;
for d=1:public_tag.N
    a=unicode2native(public_tag.dict{d,1},'UTF-8');
    b=size(a);
    b=b(1,2);
    for e=1:b
        c(1,f+e)=a(1,e);
    end
    out(9+8*d:12+8*d)=longs2bytes(public_tag.N*8+16+f);
    out(13+8*d:16+8*d)=longs2bytes(b);
    f=f+b;
end
g=size(c);
g=g(1,2);
out(17+8*d:16+8*d+g)=c;

function out=encode_Spectral_data_Type(public_tag)
out=zeros(1,public_tag.zise);
out(1:4) = uint8(public_tag.tagtype);
a=uint8(public_tag.ColorSignature);
out(9:10) =[char(a(1,1),char(a(1,2)))];
a=a-48;
b=a(1,3)*16+a(1,4);
c=a(1,5)*16+a(1,6);
out(11:12)=[b,c];
out(13:14)=newfl16(public_tag.SpectralPCSRange.Start);
out(15:16)=newfl16(public_tag.SpectralPCSRange.End );
out(17:18)=shorts2bytes(public_tag.SpectralPCSRange.Step);

function out=encode_tag_Struct_type(public_tag)
out=public_tag.data';

function out=encode_mulit_Process_Elements_Type(public_tag)
% out=public_tag.data;
%首先将元素编码
size_Element=size(public_tag.func);
number_Element=size_Element(1,1);
data=cell(number_Element,1);
for i=1:number_Element
    switch public_tag.func{i,1}
        case 'calc'
            data{i,1}=encode_calc_element(public_tag.func{i,2});
        case 'cvst'
            data{i,1}=encode_cvst_element(public_tag.func{i,2});
        case 'clut'
            data{i,1}=encode_clut_element(public_tag.func{i,2});
        case 'eclt'
        case 'emtx'
        case 'eobs'
        case 'xclt'
        case 'iemx'
        case 'JtoX'
            %JtoX元素固定是44字节
            data_JtoX=encode_JtoX_element(public_tag.func{i,2});
            sig=uint8('JtoX');
            data{i,1}=[sig,data_JtoX];
        case 'matf'
            data{i,1}=encode_matf_element(public_tag.func{i,2});
        case 'smet'
        case 'rclt'
        case 'robs'
        case 'tint'
            data{i,1}=encode_tint_element(public_tag.func{i,2});
        case 'XtoJ'
            %XtoJ元素固定是44字节
            data_JtoX=encode_JtoX_element(public_tag.func{i,2});
            sig=uint8('XtoJ');
            data{i,1}=[sig,data_JtoX];
        otherwise
    end
end
front_element=zeros(1,16+8*number_Element);
front_element(1:4)=uint8(public_tag.tagtype);
front_element(9:10)=shorts2bytes(public_tag.P);
front_element(11:12)=shorts2bytes(public_tag.Q);
front_element(13:16)=longs2bytes(uint32(public_tag.N));
number_func=16+8*number_Element;
for j=1:number_Element
    size_func=size(data{j,1});
    size_func=size_func(1,2);
    % front_element(17:20)第一个函数的offset 
    front_element(17+(j-1)*8:20+(j-1)*8)=longs2bytes(uint32(number_func));
    % front_element(21:24)第一个函数的size 
    front_element(21+(j-1)*8:24+(j-1)*8)=longs2bytes(uint32(size_func));
    number_func=number_func+size_func;
    front_element=[front_element,data{j,1}];
end
out=front_element;

function out=encode_JtoX_element(a)
out=zeros(1,40);
out(5:6)=shorts2bytes(a.numP);
out(7:8)=shorts2bytes(a.numQ);
out(9:20)=newfloat(a.White_XYZ);
% out(13:16)=newfloat(a.White_XYZ(1,2));
% out(17:20)=newfloat(a.White_XYZ(1,3));
out(21:24)=newfloat(a.Luminance);
out(25:28)=newfloat(a.Background_luminance);
out(29:32)=newfloat(a.Impact);
out(33:36)=newfloat(a.Chromatic);
out(37:40)=newfloat(a.Adaptation);

function out=encode_matf_element(element)
size_element=size(element.Matrix_elements);
out=zeros(1,12+(size_element(1,1)+1)*size_element(1,2)*4);
out(1:4)=uint8('matf');
out(9:10)=shorts2bytes(size_element(1,1));
out(11:12)=shorts2bytes(size_element(1,2));
for i=1:size_element(1,2)
    out(13+(i-1)*4*size_element(1,1):12+4*size_element(1,1)+(i-1)*4*size_element(1,1))=newfloat(element.Matrix_elements(:,i)');
end
out(13+4*i*size_element(1,1):12+(size_element(1,1)+1)*size_element(1,2)*4)=newfloat(element.e');

function out=encode_cvst_element(element)
size_sample=size(element.sample);

pre_part=zeros(1,12);
pre_part(1:4)=uint8('cvst');
pre_part(9:10)=shorts2bytes(size_sample(1,1));
pre_part(11:12)=shorts2bytes(size_sample(1,1));


data=cell(size_sample(1,1),2);
%data(1,1)存放各个曲线的数据
%data(1,1)存放各个曲线的尺寸
for i=1:size_sample(1,1)
    switch element.sample{i,1}
        case 'sngf'
            
        case 'curf'
            size_curf=size(element.sample{i,2}.Parameters);
            size_curf=size_curf(1,1);
            if size_curf==1
                curf=zeros(1,12);
            else
                curf=zeros(1,12+(size_curf-1)*4);
                a=element.sample{i,2};
                curf(13:12+(size_curf-1)*4)=newfloat(a.Break_Points);
            end
            curf(1:4)=uint8('curf');
            curf(9:10)=shorts2bytes(size_curf);
            for j=1:size_curf
               switch element.sample{i,2}.Parameters{j,1}
                   case 'parf'
                       mid_curf=zeros(1,12);
                       mid_curf(1:4)=uint8('parf');
                       switch element.sample{i,2}.Parameters{j,2}
                           case 0 
                               mid_curf(9:10)=shorts2bytes(0);
                               hid_curf=newfloat(element.sample{i,2}.Parameters{j,3});
                           case 1
                               mid_curf(9:10)=shorts2bytes(1);
                               hid_curf=newfloat(element.sample{i,2}.Parameters{j,3});
                           case 2
                               mid_curf(9:10)=shorts2bytes(2);
                               hid_curf=newfloat(element.sample{i,2}.Parameters{j,3});
                           case 3 
                               mid_curf(9:10)=shorts2bytes(3);
                               hid_curf=newfloat(element.sample{i,2}.Parameters{j,3});
                       end
                   case 'samf'
                       
               end
               curf=[curf,mid_curf,hid_curf];
            end
            
        otherwise
    end
    %建立一个类似于查找表的矩阵，然后用矩阵的前N项合来计算其
    data{i,1}=curf;
    size_curf=size(curf);
    data{i,2}=size_curf(1,2);
end

size_offset_sample=zeros(1,8*size_sample(1,1));
data_all=[];
sum_data=12+8*size_sample(1,1);
for i=1:size_sample(1,1)
    %实现将各组数据拼合
    %实现将偏移量和尺寸拼合
    data_part=data{i,1};
    data_all=[data_all,data_part];
    size_offset_sample(1+(i-1)*8:4+(i-1)*8)=longs2bytes(uint32(sum_data));
    size_offset_sample(5+(i-1)*8:8+(i-1)*8)=longs2bytes(uint32(data{i,2}));
    sum_data=sum_data+data{i,2};
end
out=[pre_part,size_offset_sample,data_all];

function out=encode_clut_element(element)
% numb=find(element.num_grid==0);
% size_numb=size(numb);
% if size_numb(1,1)==0
%     P=16;
% else
%     P=numb(1,1)-1;
% end
% num_grid=1;
% for i=1:P
%     num_grid=num_grid*element.num_grid(i,1);
% end
pre_clut=zeros(1,28);
pre_clut(1:4)=uint8('clut');
pre_clut(9:10)=shorts2bytes(element.numP);
pre_clut(11:12)=shorts2bytes(element.numP);
pre_clut(13:28)=uint8(element.num_grid');
% grid_clut=zeros(1,num_grid*4);
grid_clut=newfloat(element.lut');
out=[pre_clut,grid_clut];

function out=encode_tint_element(element)
pre_tint=zeros(1,20);
pre_tint(1:4)=uint8('tint');
pre_tint(9:10)=shorts2bytes(1);
pre_tint(11:12)=shorts2bytes(element.numQ);
pre_tint(13:16)=longs2bytes(uint32(element.type));
switch element.type
    case 0
        %float32
        titn_array=newfloat(element.Arrart');
    case 1
        %float16
        titn_array=newfloat(element.Arrart');
    case 2
        %uint16
        titn_array=shorts2bytes(element.Arrart');
    case 3
        %uint8
        titn_array=element.Arrart';
    otherwise 
        titn_array=[];
end
out=[pre_tint,titn_array];

function out=encode_calc_element(element)
%前半部分
pre_clac=zeros(1,16);
pre_clac(1:4)=uint8('calc');
pre_clac(9:10)=shorts2bytes(element.numP);
pre_clac(11:12)=shorts2bytes(element.numQ);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%table 主函数的数据
table_size=size(element.table);
data_table=zeros(1,8*table_size(1,1));
for j=1:table_size(1,1)
    data_table(1+8*(j-1):4+8*(j-1))=uint8(element.table{j,1});
    data_table(5+8*(j-1):8+8*(j-1))=(element.table{j,2});
end
pre_table=zeros(1,12);
pre_table(1:4)=uint8('func');
pre_table(9:12)=longs2bytes(uint32(table_size(1,1)));
table=[pre_table,data_table];
%%%%%%%%

isfunc=isfield(element,'sub');
if isfunc
    size_func=size(element.sub);
    data_sub=cell(size_func(1,1),2);
    for i=1:size_func(1,1)
        switch element.sub{i,1}
            case 'calc'
                a=encode_calc_element(element.sub{i,2});
            case 'cvst'
                a=encode_cvst_element(element.sub{i,2});
            case 'clut'
                a=encode_clut_element(element.sub{i,2});
            case 'eclt'
                a=encode_eclt_element(element.sub{i,2});
            case 'emtx'
                a=encode_emtx_element(element.sub{i,2});
            case 'eobs'
                a=read_eobs_element(element.sub{i,2});
            case 'xclt'
                a=encode_xclt_element(element.sub{i,2});
            case 'iemx'
                a=encode_iemx_element(element.sub{i,2});
            case 'JtoX'
                data_JtoX=encode_JtoX_element(element.sub{i,2});
                sig=uint8('JtoX');
                a=[sig,data_JtoX];
            case 'matf'
                a=encode_matf_element(element.sub{i,2});
            case 'smet'
                a=encode_smet_element(element.sub{i,2});
            case 'rclt'
                a=encode_rclt_element(element.sub{i,2});
            case 'robs'
                a=encode_robs_element(element.sub{i,2});
            case 'tint'
                a=encode_tint_element(element.sub{i,2});
            case 'XtoJ'
                data_JtoX=encode_JtoX_element(element.sub{i,2});
                sig=uint8('XtoJ');
                a=[sig,data_JtoX];
                %            case 'bACS'
                %            case 'eACS'
            otherwise
        end
        data_sub{i,1}=a;
        b=size(a);
        data_sub{i,2}=b(1,2);
    end
else
    size_func=0;
end

pre_clac(13:16)=longs2bytes(uint32(size_func(1,1)));

offset_size=zeros(1,8*size_func(1,1)+8);
offset_size(1:4)=longs2bytes(uint32(24+8*size_func(1,1)));
offset_size(5:8)=longs2bytes(uint32(j*8+12+40));
data_all=[];
sum_sub=36+8*size_func(1,1)+8*table_size(1,1);
for k=1:size_func(1,1)
    data_all=[data_all,data_sub{k,1}];
    offset_size(1+8*k:4+8*k)=longs2bytes(uint32(sum_sub));
    sum_sub=sum_sub+data_sub{k,2};
    offset_size(5+8*k:8+8*k)=longs2bytes(uint32(data_sub{k,2}));
end
out=[pre_clac,offset_size,table,data_all];

