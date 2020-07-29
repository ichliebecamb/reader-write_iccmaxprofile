function s = iccmaxread(filename)
%ICCREAD Read ICC color profile.
%   P = ICCREAD(FILENAME) reads the International Color Consortium (ICC)
%   color profile data from the file specified by FILENAME.  The file can
%   be either an ICC profile file or a TIFF file containing an embedded
%   ICC profile.  ICCREAD returns the profile information in the
%   structure P, which can be used by MAKECFORM and APPLYCFORM to compute
%   color space transformations.  P can also be written to a new
%   ICC profile file by ICCWRITE.  Both Version 2 and Version 4
%   of the ICC specification are supported.
%
%   The reference page for ICCREAD has additional information about the
%   fields of the structure P.  For complete details, see the
%   specifications ICC.1:2001-04 for Version 2 and ICC.1:2001-12
%   for Version 4.0 or ICC.1:2004-10 for Version 4.2.0.0 (available
%   at www.color.org).
%
%   Example
%   -------
%   Read in the sRGB profile.
%
%       P = iccread('sRGB.icm');
%
%   See also ISICC, ICCWRITE, MAKECFORM, APPLYCFORM.

%   Copyright 2002-2015 The MathWorks, Inc.

% Check input argument
validateattributes(filename,{'char'},{'nonempty'},'iccread','FILENAME',1);

% Check to see that FILENAME is actually a file that exists
if exist(filename,'file') ~= 2
    
    % Look in the system's ICC profile repository.
    try
        repository = iccroot;
    catch
        repository = '';
    end
    
    if (exist(fullfile(repository, filename), 'file'))
        filename = fullfile(iccroot, filename);
    else
        error(message('images:iccread:fileNotFound'))
    end
    
end   

if istif(filename)
    info = imfinfo(filename);
    if ~isfield(info,'ICCProfileOffset')
        error(message('images:iccread:noProfileInTiffFile'))
    end
    start = info.ICCProfileOffset;
    
elseif isiccprof(filename)
    start = 0;
    
else
    error(message('images:iccread:unrecognizedFileType'))
end

% "All profile data must be encoded as big-endian."  Clause 6
[fid,msg] = fopen(filename,'r','b');
if (fid < 0)
    error(message('images:iccread:errorOpeningProfile', filename, msg));
end
s = iccread_embedded(fid, start);
fclose(fid);

s.Filename = filename;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function tf = isiccprof(filename)

tf = false;

fid = fopen(filename, 'r', 'b');
if (fid < 0)
    fclose(fid);
    return;
end

[~, count] = fread(fid, 3, 'uint32');
if count ~= 3
    fclose(fid);
    return;
end

[device_class_code, count] = fread(fid, 4, 'uchar');
if count ~= 4
    fclose(fid);
    return;
end
valid_device_classes = get_iccmax_device_classes;
if any(strcmp(char(device_class_code'), valid_device_classes(:, 1)))
    tf = true;
end

fclose(fid);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function tf = istif(filename)

fid = fopen(filename, 'r', 'ieee-le');
if (fid < 0)
    tf = false;
else
    sig = fread(fid, 4, 'uint8');
    fclose(fid);
    tf = isequal(sig, [73; 73; 42; 0]) | isequal(sig, [77; 77; 0; 42]);
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function s = iccread_embedded(fid, start)
%   ICCREAD_EMBEDDED(FID, START) reads ICC profile data using the file
%   identifier FID, starting at byte offset location START, as measured
%   from the beginning of the file.

fseek_check(fid, start, 'bof');

s.Header = read_header(fid);
version = sscanf(s.Header.Version(1), '%d%');

% Skip past header -- 128 bytes (Clause 6.1)
fseek_check(fid, start + 128, 'bof');     % Use fixed length of header

% Read the Tag Table
tag_count = fread_check(fid, 1, 'uint32');
tag_table = cell(tag_count,3);
for k = 1:tag_count
    tag_table{k,1} = char(fread_check(fid, 4, '*uint8'))';
    tag_table{k,2} = fread_check(fid, 1, 'uint32');
    tag_table{k,3} = fread_check(fid, 1, 'uint32');
end
s.TagTable = tag_table;

% Build up a list of defined public tags
public_tagnames = get_icc_public_tagnames(version);
mattrc_tagnames = get_mattrc_tagnames(version);

private_tags = cell(0,0);
has_mattrc = false;
% Go through each tag in the tag table
for k = 1:size(s.TagTable,1)
    signature = deblank(s.TagTable{k,1});
    offset = s.TagTable{k,2};
    data_size = s.TagTable{k,3};
    
    pub_idx = strmatch(signature,public_tagnames,'exact');
    mattrc_idx = strmatch(signature,mattrc_tagnames,'exact');
    
    % Check to see if the tag is public, a mattrc tag, or private
    if ~isempty(pub_idx)
        % A public tag is found
        tagname = public_tagnames{pub_idx, 2};
        s.(tagname) = get_public_tag(fid, signature, offset + start, ...
            data_size, version, s.Header.ConnectionSpace, tagname);
    elseif ~isempty(mattrc_idx)
        % A Mattrc element is found... and the MatTRC struct will
        % now be generated or appended.
        has_mattrc = true;
        tagname = mattrc_tagnames{mattrc_idx, 2};
        MatTRC.(tagname) = get_public_tag(fid, signature, offset + start, ...
            data_size, version, s.Header.ConnectionSpace, tagname);
    else
        % The tag is a private tag
        data = get_private_tag(fid,offset+start,data_size);
        current_row = size(private_tags,1)+1;
        private_tags{current_row,1} = signature;
        private_tags{current_row,2} = data;
    end
end

% Generate the MatTRC field
if has_mattrc
    s.MatTRC = MatTRC;
end

% Populate the private tags
s.PrivateTags = private_tags;

% Verify the checksum if present and nonzero.
if isfield(s.Header, 'ProfileID') && any(s.Header.ProfileID)
    fseek_check(fid, start, 'bof');
    bytes = fread_check(fid, s.Header.Size, '*uint8');
    % See clause 6.1.13.  The checksum is computed after setting bytes
    % 44-47 (indexed from 0), 64-67, and 84-99 to 0.
    bytes([45:48 65:68 85:100]) = 0;
    digest = compute_md5(bytes);
    if ~isequal(digest, s.Header.ProfileID)
        warning(message('images:iccread:badChecksum'));
    end
end

%------------------------------------------
function header = read_header(fid)

% Clause 6.1.1 - Profile size
header.Size = fread_check(fid, 1, 'uint32');

% Clause 6.1.2 - CMM Type
header.CMMType = char(fread_check(fid, 4, 'uint8'))';

% Clause 6.1.3 - Profile Version
% Byte 0:  Major Revision in BCD
% Byte 1:  Minor Revision & Bug Fix Revision in each nibble in BCD
% Byte 2:  Reserved; expected to be 0
% Byte 3:  Reserved; expected to be 0

version_bytes = fread_check(fid, 4, 'uint8');
major_version = version_bytes(1);

% Minor version and bug fix version are in the two nibbles
% of the second version byte.
minor_version = bitshift(version_bytes(2), -4);
bugfix_version = bitand(version_bytes(2), 15);
header.Version = sprintf('%d.%d.%d', major_version, minor_version, ...
    bugfix_version);

% Clause 6.1.4 - Profile/Device Class signature
% Profile/Device Class               Signature
% ------------                       ---------
% Input Device profile                'scnr'
% Display Device profile              'mntr'
% Output Device profile               'prtr'
% DeviceLink profile                  'link'
% ColorSpace Conversion profile       'spac'
% Abstract profile                    'abst'
% Named Color profile                 'nmcl'

device_classes = get_iccmax_device_classes(major_version);
device_class_char = char(fread_check(fid, 4, '*uint8'))';
idx = strmatch(device_class_char, device_classes(:, 1), 'exact');
if isempty(idx)
    fclose(fid);
    error(message('images:iccread:invalidProfileClass'))
end
header.DeviceClass = device_classes{idx, 2};

% Clause 6.1.5 - Color Space signature
% Four-byte string, although some signatures have a blank
% space at the end.  Translate into more readable string.
colorspaces = get_iccmax_colorspaces(major_version);
b=fread_check(fid, 4, '*uint8');
if b<'nc0001'
    if b==[0,0,0,0]
        idx=1;
    else
        signature = char(b)';
        idx = strmatch(signature, colorspaces(:, 1), 'exact');
    end
elseif b>'ncFFFF'
    signature = char(b)';
    idx = strmatch(signature, colorspaces(:, 1), 'exact');
else
    header.ColorSpace = 'N channel device data';
    idx = 1;
end
if isempty(idx)
    fclose(fid);
    error(message('images:iccread:invalidColorSpaceSignature'));
else
    header.ColorSpace = colorspaces{idx, 2};
end

% Clause 6.1.6 - Profile connection space signature
% Either 'XYZ ' or 'Lab '.  However, for a DeviceLink
% profile, the connection space signature is taken from the
% colorspace signatures table.
c = fread_check(fid, 4, '*uint8');
if c== [0;0;0;0]
    header.ConnectionSpace = 'None' ;
else
    signature = char(c)';
    if strcmp(header.DeviceClass, 'device link')
        idx = strmatch(signature, colorspaces(:, 1), 'exact');
        if isempty(idx)
            fclose(fid);
            error(message('images:iccread:invalidConnectionSpaceSignature'));
        else
            header.ConnectionSpace = colorspaces{idx, 2};
        end
    else
        switch signature
            case 'XYZ '
                header.ConnectionSpace = 'XYZ';
            case 'Lab '
                header.ConnectionSpace = 'Lab';
            otherwise
                header.ConnectionSpace = 'unkown';
                %fclose(fid);
                %error(message('images:iccread:invalidConnectionSpaceSignature'));
        end
    end
end

date_time_num = read_date_time_number(fid);
n = datenum(date_time_num(1), date_time_num(2), date_time_num(3), ...
    date_time_num(4), date_time_num(5), date_time_num(6));
header.CreationDate = datestr(n,0);

header.Signature = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(header.Signature, 'acsp')
    fclose(fid);
    error(message('images:iccread:invalidFileSignature'));
end

% Clause 6.1.7 - Primary platform signature
% Four characters, though one code ('SGI ') ends with a blank space.
% Zeros if there is no primary platform.
signature = char(fread_check(fid, 4, '*uint8'))';
if isequal(double(signature), [0 0 0 0])
    header.PrimaryPlatform = 'none';
else
    switch signature
        case 'APPL'
            header.PrimaryPlatform = 'Apple';
        case 'MSFT'
            header.PrimaryPlatform = 'Microsoft';
        case 'SGI '
            header.PrimaryPlatform = 'SGI';
        case 'SUNW'
            header.PrimaryPlatform = 'Sun';
        case 'TGNT'
            header.PrimaryPlatform = 'Taligent';
        otherwise
            header.PrimaryPlatform = signature;
            warning(message('images:iccwrite:invalidPrimaryPlatform'))
    end
end

% Clause 6.1.8 - Profile flags
% Flags containing CMM hints.  The least-significant 16 bits are reserved
% by ICC, which currently defines position 0 as "0 if not embedded profile,
% 1 if embedded profile" and position 1 as "1 if profile cannot be used
% independently of embedded color data, otherwise 0."
header.Flags = fread_check(fid, 1, 'uint32');
header.IsEmbedded = bitget(header.Flags, 1) == 1;
header.IsIndependent = bitget(header.Flags, 2) == 0;

% Clause 6.1.9 - Device manufacturer and model
header.DeviceManufacturer = char(fread_check(fid, 4, '*uint8'))';
header.DeviceModel = char(fread_check(fid, 4, '*uint8'))';

% Clause 6.1.10 - Attributes
% Device setup attributes, such as media type.  The least-significant 32
% bits of this 64-bit value are reserved for ICC, which currently defines
% bit positions 0 and 1.

% UPDATE FOR ICC:1:2001-0 Clause 6.1.10 -- Bit positions 2 and 3
% POSITION 2: POSITIVE=0, NEGATIVE=1
% POSITION 3: COLOR=0, BLACK AND WHT=1

fseek_check(fid, 4, 'cof');
header.Attributes = fread_check(fid, 1, 'uint32')';
header.IsTransparency = bitget(header.Attributes, 1) == 1;
header.IsMatte = bitget(header.Attributes, 2) == 1;
header.IsNegative = bitget(header.Attributes, 3) == 1;
header.IsBlackandWhite = bitget(header.Attributes, 4) == 1;
header.IsPaperornot = bitget(header.Attributes, 5) ==1;
header.IsNontextured = bitget(header.Attributes, 6) ==1;
header.ISNonselfluminous = bitget(header.Attributes, 7) ==1;

% Clause 6.1.11 - Rendering intent
value = fread_check(fid, 1, 'uint32');
% Only check the first two bits.
value = bitand(value, 3);
switch value
    case 0
        header.RenderingIntent = 'perceptual';
    case 1
        header.RenderingIntent = 'relative colorimetric';
    case 2
        header.RenderingIntent = 'saturation';
    case 3
        header.RenderingIntent = 'absolute colorimetric';
end

% Clause 6.1 - Table 9
header.Illuminant = read_xyz_number(fid);

% Clause 6.1.12 - Profile creator
header.Creator = char(fread_check(fid, 4, '*uint8'))';

% Clause 6.1.13 (v. 4) - Profile ID
if major_version > 2
    header.ProfileID = fread_check(fid, 16, '*uint8')';
end
%100~103 光谱PCS字段
psc1 = char(fread_check(fid, 1, '*uint8')');
mcs2 = char(fread_check(fid, 1, '*uint8')');
psc3 = fread_check(fid, 1, '*uint8')';
mcs3 = dec2hex(psc3,2);
msc3=char(psc3);
psc4 = fread_check(fid, 1, '*uint8')';
mcs4 = dec2hex(psc4');
msc4=char(psc4);
header.SpectralPCS.Sig = [psc1,mcs2,mcs3,mcs4];
header.SpectralPCS.val = [psc1,mcs2,msc3,msc4];

%104~109 光谱PCS范围字段
value = fread_check(fid, 3, '*uint16');
header.SpectralPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
header.SpectralPCSRange.End = uint16(floatSpRang2int(double(value(2))));
header.SpectralPCSRange.Step= value(3);
%110~115 双光谱PSC范围字段
value = fread_check(fid, 3, '*uint16');

header.BIPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
header.BIPCSRange.End = uint16(floatSpRang2int(double(value(2))));
header.BIPCSRange.Step= value(3);
%116~119 MCS
switch header.DeviceClass
    case 'MaterialIdentification'
        mcs1 = char(fread_check(fid, 1, '*uint8')');
        mcs2 = char(fread_check(fid, 1, '*uint8')');
        mcs3 = dec2hex(fread_check(fid, 1, '*uint8')',2);
        mcs4 = dec2hex(fread_check(fid, 1, '*uint8')',2);
        mcs5=[mcs1,mcs2,mcs3,mcs4];
        header.MCS = mcs5;
    case 'MaterialVisualization'
        mcs1 = char(fread_check(fid, 1, '*uint8')');
        mcs2 = char(fread_check(fid, 1, '*uint8')');
        mcs3 = dec2hex(fread_check(fid, 1, '*uint8')',2);
        mcs4 = dec2hex(fread_check(fid, 1, '*uint8')',2);
        mcs5=[mcs1,mcs2,mcs3,mcs4];
        header.MCS = mcs5;
    case 'input'
        mcs = fread_check(fid, 1, '*uint8')';
        mcs1=char(fread_check(fid, 1, '*uint8')');
        mcs2 = char(fread_check(fid, 1, '*uint8')');
        mcs3 = dec2hex(fread_check(fid, 1, '*uint8')',2);
        mcs4 = dec2hex(fread_check(fid, 1, '*uint8')',2);
        header.MCS = [mcs1,mcs2,mcs3,mcs4];
    otherwise
        header.MCS = 0;
end
%120~123 none output
a = char(fread_check(fid, 4, '*uint8')');
%124~127 profile /设备子类
header.ProfileandDevicesubclass = char(fread_check(fid, 4, '*uint8')');




%------------------------------------------
% Read public Tags

function out = get_public_tag(fid, signature, offset, data_size, ...
    version, pcs, tagname)

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

switch signature
    case lut_types
        % See Clauses 6.4.* (v. 2) and 9.2.* (v. 4.2)
        fseek_check(fid, offset, 'bof');
        type = char(fread_check(fid, 4, '*uint8'))';
        if type=='mpet'
            out=read_mulit_Process_Elements_Type(fid,offset,data_size,tagname);
        else
            out = read_lut_type(fid, offset, data_size, version, tagname);
        end
    case xyz_types
        % Clauses 6.4.* (v. 2) and 9.2.* (v. 4.2)
        out = read_xyz_type(fid, offset, data_size, tagname);
    case curve_types
        % Clauses 6.4.* (v. 2) and 9.2.* (v. 4.2)
        out = read_curve_type(fid, offset, data_size, version, tagname);
    case text_desc_types
        % Clauses 6.4.* (v. 2) and 9.2.* (v. 4.2)
        if version <= 2
            out = read_text_description_type(fid, offset, data_size, tagname);
        else
            out = read_unicode_type(fid, offset, data_size, tagname);
        end
    case text_types
        % Clauses 6.4.* (v. 2) and 9.2.10 (v. 4.2)
        fseek_check(fid, offset, 'bof');
        type = char(fread_check(fid, 4, '*uint8'))';
        if type=='desc'
            out = read_text_description_type(fid, offset, data_size, tagname);
        else
            out = read_text_type(fid, offset, data_size, tagname);
        end
    case non_interpreted_types
        % Clauses 6.4.* (v. 2)
        fseek_check(fid, offset, 'bof');
        out = fread_check(fid, data_size, '*uint8')';
        
    case 'calt'
        % Clause 6.4.9 (v. 2) and 9.2.9 (v. 4.2)
        out = read_date_time_type(fid, offset, data_size, tagname);
        
    case 'chad'
        % Clause 6.4.11 (v. 2) and 9.2.11 (v. 4.2)
        out = read_sf32_type(fid, offset, data_size, tagname);
        
    case 'chrm'
        % Clause 9.2.12 (v. 4.2)
        out = read_chromaticity_type(fid, offset, data_size, tagname);
        
    case 'clro'
        % Clause 9.2.13 (v. 4.2)
        out = read_colorant_order_type(fid, offset, data_size, tagname);
        
    case {'clrt', 'clot'}
        % Clause 9.2.14 (v. 4.2)
        out = read_colorant_table_type(fid, offset, data_size, pcs, tagname);
        
    case 'crdi'
        % Clause 6.4.14 (v. 2) or 6.4.16 (v. 4.0)
        out = read_crd_info_type(fid, offset, data_size, tagname);
        
    case 'meas'
        % Clause 9.2.23 (v. 4.2)
        out = read_measurement_type(fid, offset, data_size, tagname);
    case measurementinfo_Type
        out = read_measurementinfo_type(fid, offset, data_size, tagname);
        
    case 'ncl2'
        % Clause 9.2.26 (v. 4.2)
        fseek_check(fid, offset, 'bof');
        tagtype = char(fread_check(fid, 4, '*uint8'))';
        if strcmp(tagtype, 'tary')
            out = read_tag_Array_Type(fid,offset,data_size,tagname);
        else
            out = read_named_color_type(fid, offset, data_size, pcs, tagname);
        end
    case 'pseq'
        % Clause 9.2.32 (v. 4.2)
        out = read_profile_sequence_type(fid, offset, data_size, ...
            version, tagname);
        
    case 'resp'
        % Clause 9.2.27 (v. 4.2)
        out = read_response_curve_set16_type(fid, offset, data_size, tagname);
        
    case signature_Type
        % Clause 9.2.35 (v. 4.2)
        out = read_signature_type(fid, offset, data_size, tagname);
        
    case 'view'
        % Clause 6.4.47 (v. 2) or 9.2.37 (v. 4.2)
        out = read_viewing_conditions(fid, offset, data_size, tagname);
    case 'meta'
        out = read_dict_Type(fid,offset,data_size,tagname);
    case {'swpt','mdv','smwp'}
        fseek_check(fid, offset, 'bof');
        tagtype = char(fread_check(fid, 4, '*uint8'))';
        if strcmp(tagtype, 'smat')
            out = read_sparse_Matrix_Type(fid,offset,data_size,tagname);
        else
            out = read_Array_Type(fid,offset,data_size,tagname);
        end
    case gamut_Boundary_Description_Type
        out=read_gamut_Boundary_Description_Type(fid,offset,data_size,tagname);
    case 'svcn'
        out=read_specral_Viewing_condition_Type(fid,offset,data_size,tagname);
    case utlf8_Type
        out=read_utlf8_Type(fid,offset,data_size,tagname);
    case mulit_Process_Elements_Type
        out=read_mulit_Process_Elements_Type(fid,offset,data_size,tagname);
    case tag_Array_Type
        out=read_tag_Array_Type(fid,offset,data_size,tagname);
    case tag_Struuct_type
        out=read_tag_Struct_type(fid,offset,data_size,tagname);
    case 'smwi'
        out=reaad_Spectral_data_Type(fid,offset,data_size,tagname);
    otherwise
        fseek_check(fid, offset, 'bof');
        out = fread_check(fid, data_size, '*uint8')';
end

% If there was a problem, treat as uninterpreted
if isempty(out)
    fseek_check(fid, offset, 'bof');
    out = fread_check(fid, data_size, '*uint8')';
end

%------------------------------------------
% Read private tags

function out = get_private_tag(fid,offset,data_size)
fseek_check(fid, offset, 'bof');
out = fread_check(fid, data_size, '*uint8')';

%------------------------------------------
%%% read_sf32_type

function out = read_sf32_type(fid, offset, data_size, tagname)

% Clause 6.5.14 (v. 2) or 10.18 (v. 4.2)
% 0-3  'sf32'
% 4-7  reserved, must be 0
% 8-n  array of s15Fixed16Number values

if data_size < 8
    warning(message('images:iccread:invalidDataSize', tagname));
    out = [];
    return;
end
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(tagtype, 'sf32')
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''sf32''', '6.5.14 (v. 2), 6.5.19 (v. 4)'))
    out = [];
    return;
end
fseek_check(fid, offset + 8, 'bof');
num_values = (data_size - 8) / 4;
out = fread_check(fid, num_values, 'int32') / 65536;
out = reshape(out, 3, num_values/3)';


%------------------------------------------
% read_xyz_number

function out = read_xyz_number(fid)

% Clause 5.3.10 (v. 2) and 5.1.11 (v. 4.2)
% 0-3  CIE X    s15Fixed16Number
% 4-7  CIE Y    s15Fixed16Number
% 8-11 CIE Z    s15Fixed16Number

out = fread_check(fid, 3, 'int32')' / 65536;

%------------------------------------------
%%% read_xyz_type

function out = read_xyz_type(fid, offset, data_size, tagname)

% Clause 6.5.26 (v. 2) or 10.27 (v. 4.2)
% 0-3  'XYZ '
% 4-7  reserved, must be 0
% 8-n  array of XYZ numbers

if data_size < 8
    fclose(fid);
    error(message('images:iccread:invalidTagSize1', tagname));
end
fseek_check(fid, offset, 'bof');
xyztype = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(xyztype, 'XYZ ')
    fclose(fid);
    error(message('images:iccread:invalidTagType', tagname, '''XYZ '''))
end
fseek_check(fid, offset + 8, 'bof');
num_values = (data_size - 8) / 4;
if rem(num_values,3) ~= 0
    fclose(fid);
    error(message('images:iccread:invalidTagSize2', tagname, 'Clauses 5.3.10 and 6.5.26 for v. 2 or 6.5.30 for v. 4'))
end
out = fread_check(fid, num_values, 'int32') / 65536;
out = reshape(out, 3, num_values/3)';

%------------------------------------------
%%% read_chromaticity_type

function out = read_chromaticity_type(fid, offset, data_size, tagname)

% Clause 10.2 (v. 4.2)
% 0-3    'chrm'
% 4-7    reserved, must be 0
% 8-9    number of device channels
% 10-11  encoded phosphor/colorant type
% 12-19  CIE xy coordinates of 1st channel
% 20-end CIE xy coordinates of remaining channels

if data_size < 12
    fclose(fid);
    error(message('images:iccread:invalidTagSize1', tagname));
end
fseek_check(fid, offset, 'bof');
signature = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(signature, 'chrm')
    fclose(fid);
    error(message('images:iccread:invalidTagType', tagname, '''chrm'''))
end
out = struct('ColorantCode', [], 'ColorantType', [], 'xy', []);
fseek_check(fid, offset + 8, 'bof');
numchan = fread_check(fid, 1, 'uint16');
out.xy = zeros(numchan, 2);
colorantcode = fread_check(fid, 1, '*uint16');
out.ColorantCode = colorantcode;
switch colorantcode
    case 1
        out.ColorantType = 'ITU-R BT.709';
    case 2
        out.ColorantType = 'SMPTE RP145-1994';
    case 3
        out.ColorantType = 'EBU Tech.3213-E';
    case 4
        out.ColorantType = 'P22';
    otherwise
        out.ColorantType = 'unknown';
end

for i = 1 : numchan
    out.xy(i, 1) = fread_check(fid, 1, 'uint32') / 65536.0;
    out.xy(i, 2) = fread_check(fid, 1, 'uint32') / 65536.0;
end

%------------------------------------------
%%% read_colorant_order_type

function out = read_colorant_order_type(fid, offset, data_size, tagname)

% Clause 10.3 (v. 4.2)
% 0-3    'clro'
% 4-7    reserved, must be 0
% 8-11   number of colorants n
% 12     index of first colorant in laydown
% 13-end remaining (n - 1) indices, in laydown order

if data_size < 12
    fclose(fid);
    error(message('images:iccread:invalidTagSize1', tagname));
end
fseek_check(fid, offset, 'bof');
signature = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(signature, 'clro')
    fclose(fid);
    error(message('images:iccread:invalidTagType', tagname, '''clro'''))
end
fseek(fid, offset + 8, 'bof');
numchan = fread_check(fid, 1, 'uint32');
out = zeros(1, numchan);
for i = 1 : numchan
    out(i) = fread_check(fid, 1, 'uint8');
end

%------------------------------------------
%%% read_colorant_table_type

function out = read_colorant_table_type(fid, offset, data_size, pcs, tagname)

% Clause 10.4 (v. 4.2)
% 0-3    'clrt'
% 4-7    reserved, must be 0
% 8-11   number of colorants n
% 12-43  name of first colorant, NULL terminated
% 44-49  PCS values of first colorant as uint16
% 50-end name and PCS values of remaining colorants

if data_size < 12
    fclose(fid);
    error(message('images:iccread:invalidTagSize1', tagname));
end
fseek_check(fid, offset, 'bof');
signature = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(signature, 'clrt')
    fclose(fid);
    error(message('images:iccread:invalidTagType', tagname, '''clrt'''))
end

fseek_check(fid, offset + 8, 'bof');
numchan = fread_check(fid, 1, 'uint32');
out = cell(numchan, 2);
for i = 1 : numchan
    name = fread_check(fid, 32, '*uint8')';
    out{i, 1} = trim_string(name); % remove trailing zeros
    pcs16 = fread_check(fid, 3, '*uint16')';
    % Convert from uint16 to double
    out{i, 2} = encode_color(pcs16, pcs, 'uint16', 'double');
end

%------------------------------------------
%%% read_curve_type

function out = read_curve_type(fid, offset, ~, version, tagname)

% Clause 6.5.3 (v. 2) or 10.5 (v. 4.2)
% 0-3    'curv'
% 4-7    reserved, must be 0
% 8-11   count value, uint32
% 12-end curve values, uint16

% For v. 4 can also be 'para'; see Clause 10.15 (v. 4.2)

% Note:  Since this function can be called for a curveType
% embedded in another tag (lutAtoBType, lutBtoAType), the
% data_size field may be invalid -- e.g., zero.  Therefore,
% there is no check for sufficient size (= 12 + 2n bytes).

fseek_check(fid, offset, 'bof');
% Check for curv or para signature
curvetype = char(fread_check(fid, 4, '*uint8'))';
if strcmp(curvetype, 'curv')
    out = uint16(256); % Default:  gamma = 1 for empty curve
    fseek_check(fid, offset + 8, 'bof');
    count = fread_check(fid, 1, 'uint32');
    if count > 0
        out = fread_check(fid, count, '*uint16');
    end
    
elseif strcmp(curvetype, 'para') && (version > 2) % New v. 4 type
    out = struct('FunctionType', [], 'Params', []);
    fseek_check(fid, offset + 8, 'bof');
    out.FunctionType = fread_check(fid, 1, 'uint16');
    switch out.FunctionType
        case 0
            n = 1;
        case 1
            n = 3;
        case 2
            n = 4;
        case 3
            n = 5;
        case 4
            n = 7;
        otherwise
            error(message('images:iccread:invalidFunctionType', out.FunctionType, tagname))
    end
    fseek_check(fid, offset + 12, 'bof');
    out.Params = fread_check(fid, n, 'int32')' / 65536;
else
    fclose(fid);
    error(message('images:iccread:invalidTagTypeWithReference', tagname, '''curv''', '6.5.3 (v. 2), 6.5.5, 6.5.16 (v. 4)'))
end


%------------------------------------------
%%% read_lut_type

function out = read_lut_type(fid, offset, data_size, version, tagname)

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

if data_size < 32
    fclose(fid);
    error(message('images:iccread:invalidTagSize1', tagname));
end

fseek_check(fid, offset, 'bof');

% Check for signature
luttype = char(fread_check(fid, 4, '*uint8'))';
out.tagtype=luttype;
if strcmp(luttype, 'mft1')
    out.MFT = 1;
elseif strcmp(luttype, 'mft2')
    out.MFT = 2;
elseif strcmp(luttype, 'mAB ') && (version > 2) % New v. 4 lut type
    out.MFT = 3;
elseif strcmp(luttype, 'mBA ') && (version > 2) % New v. 4 lut type
    out.MFT = 4;
else
    fclose(fid);
    error(message('images:iccread:invalidTagTypeWithReference', tagname, '''mft1'', ''mft2'', ''mAB '' (v. 4), ''mBA '' (v. 4)', '6.5.7 (v. 2), 6.5.8 (v. 2), 6.5.9 (v. 4), 6.5.10 (v. 4), 6.5.11 (v. 4), 6.5.12 (v. 4)'))
end

% Skip past reserved padding bytes
fseek_check(fid, 4, 'cof');
num_input_channels = fread_check(fid, 1, 'uint8');
num_output_channels = fread_check(fid, 1, 'uint8');

% Handle older lut8Type and lut16Type
if out.MFT < 3
    % Unused elements
    out.PreShaper = [];
    out.PostMatrix = [];
    out.PostShaper = [];
    
    % Get matrix
    num_clut_grid_points = fread_check(fid, 1, 'uint8');
    fseek_check(fid, 1, 'cof');  % skip padding byte
    out.PreMatrix = reshape(fread_check(fid, 9, 'int32') / 65536, 3, 3)';
    out.PreMatrix(:, 4) = zeros(3, 1);
    
    % Get tables
    if out.MFT == 2  % lut16Type
        num_input_table_entries = fread_check(fid, 1, 'uint16');
        num_output_table_entries = fread_check(fid, 1, 'uint16');
        dataformat = '*uint16';
    else             % lut8Type
        num_input_table_entries = 256;
        num_output_table_entries = 256;
        dataformat = '*uint8';
    end
    itbl = reshape(fread_check(fid, num_input_channels * ...
        num_input_table_entries, ...
        dataformat), ...
        num_input_table_entries, ...
        num_input_channels);
    for k = 1 : num_input_channels
        out.InputTables{k} = itbl(:, k);
    end
    clut_size = ones(1, num_input_channels) * num_clut_grid_points;
    num_clut_elements = prod(clut_size);
    ndims_clut = num_output_channels;
    
    out.CLUT = reshape(fread_check(fid, num_clut_elements * ndims_clut, dataformat), ...
        ndims_clut, num_clut_elements)';
    out.CLUT = reshape( out.CLUT, [ clut_size ndims_clut ]);
    
    otbl = reshape(fread_check(fid, num_output_channels * ...
        num_output_table_entries, ...
        dataformat), ...
        num_output_table_entries, ...
        num_output_channels);
    for k = 1 : num_output_channels
        out.OutputTables{k} = otbl(:, k);
    end
else
    % Handle newer lutAtoBType and lutBtoAType
    fseek_check(fid, 2, 'cof');  % skip padding bytes
    boffset = fread_check(fid, 1, 'uint32');
    xoffset = fread_check(fid, 1, 'uint32');
    moffset = fread_check(fid, 1, 'uint32');
    coffset = fread_check(fid, 1, 'uint32');
    aoffset = fread_check(fid, 1, 'uint32');
    
    % Get B-curves (required)
    if boffset == 0
        fclose(fid);
        error(message('images:iccread:invalidLuttagBcurve', tagname))
    end
    
    if out.MFT == 3
        numchan = num_output_channels;
    else
        numchan = num_input_channels;
    end
    
    Bcurve = cell(1, numchan);
    Bcurve{1} = read_curve_type(fid, offset + boffset, 0, version, tagname);
    
    for chan = 2 : numchan
        current = ftell(fid);
        if mod(current, 4) ~= 0
            current = current + 4 - mod(current, 4);
        end
        Bcurve{chan} = read_curve_type(fid, current, 0, version, tagname);
    end
    
    % Get PCS-side matrix (optional)
    if xoffset == 0
        PMatrix = [];
    else
        fseek_check(fid, offset + xoffset, 'bof');
        PMatrix = reshape(fread_check(fid, 9, 'int32') / 65536, 3, 3)';
        PMatrix(:, 4) = fread_check(fid, 3, 'int32') / 65536;
    end
    
    % Get M-curves (optional)
    if moffset == 0
        Mcurve = [];
    elseif xoffset == 0
        fclose(fid);
        error(message('images:iccread:invalidLuttagMatrix', tagname))
    else
        Mcurve = cell(1, numchan);
        Mcurve{1} = read_curve_type(fid, offset + moffset,  0, version, tagname);
        for chan = 2 : numchan
            current = ftell(fid);
            if mod(current, 4) ~= 0
                current = current + 4 - mod(current, 4);
            end
            Mcurve{chan} = read_curve_type(fid, current, 0, version, tagname);
        end
    end
    
    % Get n-dimensional LUT (optional)
    if coffset == 0
        ndlut = [];
    else
        fseek(fid, offset + coffset, 'bof');
        gridsize = fread(fid, num_input_channels, 'uint8')';
        % Reverse order of dimensions for MATLAB
        clut_size = zeros(1, num_input_channels);
        for i = 1 : num_input_channels
            clut_size(i) = gridsize(num_input_channels + 1 - i);
        end
        num_clut_elements = prod(clut_size);
        ndims_clut = num_output_channels;
        fseek(fid, 16 - num_input_channels, 'cof');   % skip unused channels
        datasize = fread(fid, 1, 'uint8');
        if datasize == 1
            dataformat = '*uint8';
        elseif datasize == 2
            dataformat = '*uint16';
        else
            fclose(fid);
            error(message('images:iccread:invalidLuttagPrecision', tagname))
        end
        fseek(fid, 3, 'cof'); % skip over padding
        
        ndlut = reshape(fread_check(fid, num_clut_elements * ndims_clut, dataformat), ...
            ndims_clut, num_clut_elements)';
        ndlut = reshape(ndlut, [ clut_size ndims_clut ]);
    end
    
    % Get A-curves (optional)
    if aoffset == 0
        Acurve = [];
    elseif coffset == 0
        fclose(fid);
        error(message('images:iccread:invalidLuttagAcurve', tagname))
    else
        Acurve = cell(1, numchan);
        Acurve{1} = read_curve_type(fid, offset + aoffset,  0, version, tagname);
        if out.MFT == 3
            numchan = num_input_channels;
        else
            numchan = num_output_channels;
        end
        for chan = 2 : numchan
            current = ftell(fid);
            if mod(current, 4) ~= 0
                current = current + 4 - mod(current, 4);
            end
            Acurve{chan} = read_curve_type(fid, current, 0, version, tagname);
        end
    end
    
    % Assemble elements in proper sequence
    if out.MFT == 3 % lutAtoBType
        out.PreShaper = [];
        out.PreMatrix = [];
        out.InputTables = Acurve;
        out.CLUT = ndlut;
        out.OutputTables = Mcurve;
        out.PostMatrix = PMatrix;
        out.PostShaper = Bcurve;
    elseif out.MFT == 4 % lutBtoAType
        out.PreShaper = Bcurve;
        out.PreMatrix = PMatrix;
        out.InputTables = Mcurve;
        out.CLUT = ndlut;
        out.OutputTables = Acurve;
        out.PostMatrix = [];
        out.PostShaper = [];
    end
    
end

%------------------------------------------
%%% read_measurement_type

function out = read_measurement_type(fid, offset, data_size, tagname)

% Clause 10.12 (v. 4.2)
% 0-3    'meas'
% 4-7    reserved, must be 0
% 8-11   encoded standard observer
% 12-23  XYZ of measurement backing
% 24-27  encoded measurement geometry
% 28-31  encoded measurement flare
% 32-35  encoded standard illuminant
% 36~39(optional) Encoded measurement condition

if data_size < 36
    warning(message('images:iccread:invalidTagSize1', tagname));
    out = [];
    return;
end
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(tagtype, 'meas')
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''meas''', '10.12 (v. 4.2)'))
    out = [];
    return;
end

out = struct('ObserverCode', [], 'StandardObserver', [], ...
    'GeometryCode', [], 'MeasurementGeometry', [], ...
    'FlareCode', [], 'MeasurementFlare', [], ...
    'IlluminantCode', [], 'StandardIlluminant', [], ...
    'MeasurementBacking', []);

fseek_check(fid, offset + 8, 'bof');
out.ObserverCode = fread_check(fid, 1, 'uint32');
switch out.ObserverCode
    case 1
        out.StandardObserver = 'CIE 1931';
    case 2
        out.StandardObserver = 'CIE 1964';
    otherwise
        out.StandardObserver = 'unknown';
end

out.MeasurementBacking = read_xyz_number(fid);

out.GeometryCode = fread_check(fid, 1, 'uint32');
switch out.GeometryCode
    case 1
        out.MeasurementGeometry = '0/45 or 45/0';
    case 2
        out.MeasurementGeometry = '0/d or d/0';
    otherwise
        out.MeasurementGeometry = 'unknown';
end

out.FlareCode = fread_check(fid, 1, 'uint32');
out.MeasurementFlare = sprintf('%d%%', ...
    round(double(out.FlareCode) / 655.36));

out.IlluminantCode = fread_check(fid, 1, 'uint32');
switch out.IlluminantCode
    case 1
        out.StandardIlluminant = 'D50';
    case 2
        out.StandardIlluminant = 'D65';
    case 3
        out.StandardIlluminant = 'D93';
    case 4
        out.StandardIlluminant = 'F2';
    case 5
        out.StandardIlluminant = 'D55';
    case 6
        out.StandardIlluminant = 'A';
    case 7
        out.StandardIlluminant = 'E';
    case 8
        out.StandardIlluminant = 'F8';
    case 9
        out.StandardIlluminant = 'Black body';
    case 10
        out.StandardIlluminant = 'Daylight';
    case 11
        out.StandardIlluminant = 'B';
    case 12
        out.StandardIlluminant = 'C';
    case 13
        out.StandardIlluminant = 'F1';
    case 14
        out.StandardIlluminant = 'F3';
    case 15
        out.StandardIlluminant = 'F4';
    case 16
        out.StandardIlluminant = 'F5';
    case 17
        out.StandardIlluminant = 'F6';
    case 18
        out.StandardIlluminant = 'F7';
    case 19
        out.StandardIlluminant = 'F9';
    case 20
        out.StandardIlluminant = 'F10';
    case 21
        out.StandardIlluminant = 'F11';
    case 22
        out.StandardIlluminant = 'F12';
    otherwise
        out.StandardIlluminant = 'unknown';
end
out.ConditionCode = fread_check(fid, 1, 'uint32');
switch out.ConditionCode
    case 1
        out.Condition = 'M0';
    case 2
        out.Condition = 'M1';
    case 3
        out.Condition = 'M2';
    case 4
        out.Condition = 'M3';
    otherwise
        out.Condition = 'Unknown';
end
function out=read_measurementinfo_type(fid, offset, data_size, tagname)
if data_size < 40
    tagtype = 'Unknown';
else
    fseek_check(fid, offset, 'bof');
    tagtype = char(fread_check(fid, 4, '*uint8'))';
end


out = struct('ObserverCode', [], 'StandardObserver', [], ...
    'GeometryCode', [], 'MeasurementGeometry', [], ...
    'FlareCode', [], 'MeasurementFlare', [], ...
    'IlluminantCode', [], 'StandardIlluminant', [], ...
    'MeasurementBacking', []);

fseek_check(fid, offset + 8, 'bof');
out.ObserverCode = fread_check(fid, 1, 'uint32');
switch out.ObserverCode
    case 1
        out.StandardObserver = 'CIE 1931';
    case 2
        out.StandardObserver = 'CIE 1964';
    otherwise
        out.StandardObserver = 'unknown';
end

out.MeasurementBacking = read_xyz_number(fid);

out.GeometryCode = fread_check(fid, 1, 'uint32');
switch out.GeometryCode
    case 1
        out.MeasurementGeometry = '0/45 or 45/0';
    case 2
        out.MeasurementGeometry = '0/d or d/0';
    otherwise
        out.MeasurementGeometry = 'unknown';
end

out.FlareCode = fread_check(fid, 1, 'uint32');
out.MeasurementFlare = sprintf('%d%%', ...
    round(double(out.FlareCode) / 655.36));

out.IlluminantCode = fread_check(fid, 1, 'uint32');
switch out.IlluminantCode
    case 1
        out.StandardIlluminant = 'D50';
    case 2
        out.StandardIlluminant = 'D65';
    case 3
        out.StandardIlluminant = 'D93';
    case 4
        out.StandardIlluminant = 'F2';
    case 5
        out.StandardIlluminant = 'D55';
    case 6
        out.StandardIlluminant = 'A';
    case 7
        out.StandardIlluminant = 'E';
    case 8
        out.StandardIlluminant = 'F8';
    case 9
        out.StandardIlluminant = 'Black body';
    case 10
        out.StandardIlluminant = 'Daylight';
    case 11
        out.StandardIlluminant = 'B';
    case 12
        out.StandardIlluminant = 'C';
    case 13
        out.StandardIlluminant = 'F1';
    case 14
        out.StandardIlluminant = 'F3';
    case 15
        out.StandardIlluminant = 'F4';
    case 16
        out.StandardIlluminant = 'F5';
    case 17
        out.StandardIlluminant = 'F6';
    case 18
        out.StandardIlluminant = 'F7';
    case 19
        out.StandardIlluminant = 'F9';
    case 20
        out.StandardIlluminant = 'F10';
    case 21
        out.StandardIlluminant = 'F11';
    case 22
        out.StandardIlluminant = 'F12';
    otherwise
        out.StandardIlluminant = 'unknown';
end
out.ConditionCode = fread_check(fid, 1, 'uint32');
switch out.ConditionCode
    case 1
        out.Condition = 'M0';
    case 2
        out.Condition = 'M1';
    case 3
        out.Condition = 'M2';
    case 4
        out.Condition = 'M3';
    otherwise
        out.Condition = 'Unknown';
end
function out=read_dict_Type(fid,offset,data_size,tagname)
%0 to 3 ‘dict’ (64696374h) type signature
%4 to 7  Reserved, shall be 0
%8 to 11 Number of name-value records (M) uInt32Number
%12 to 15 The length of each name-value record, in bytes (N).
% The value shall be 16, 24, or 32 uInt32Number
% 16 to 15+N
% The first name-value record
% 16+N to 15+M*N Additional name-value records as needed
% 16+M*N to end (tag data element size) – (16+M*N)
% Storage area of strings of Unicode characters and multiLocalizedType tags
fseek_check(fid, offset, 'bof');
out.size=data_size;
dicttype = char(fread_check(fid, 4, '*uint8'))';
fseek_check(fid, offset + 8, 'bof');
M=fread_check(fid, 1, 'uint32');
out.M=M;
N=fread_check(fid, 1, 'uint32');
out.N=N;
switch N
    case 16
        for k=1:1:M
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            fseek_check(fid, offset+namevalue_offset, 'bof');
            b=fread_check(fid, namevalue_size, '*uint8');
            NAme_Value.name=native2unicode(b,'utf-16')';
            fseek_check(fid, offset+16+k*8, 'bof');
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            fseek_check(fid, offset+namevalue_offset, 'bof');
            b=fread_check(fid, namevalue_size, '*uint8');
            NAme_Value.value=native2unicode(b,'utf-16')';
            fseek_check(fid, offset+8+k*8, 'bof');
        end
        out.NAme_Value=NAme_Value;
    case 24
        NAme_Value=cell(1,3,M);
        for k=1:1:M
            b=fread_check(fid,4, '*uint16');
            NAme_Value{1,1,k}=native2unicode(b,'utf-16be')';
            c=fread_check(fid,4, '*uint16');
            NAme_Value{1,2,k}=native2unicode(c,'utf-16be')';
            NAme_Value{1,3,k}=char(fread_check(fid, 4, 'uint16'))';
        end
        out.NAme_Value=NAme_Value;
    case 32
        NAme_Value=cell(1,4,M);
        for k=1:1:M
            b=fread_check(fid,4, '*uint16');
            NAme_Value{1,1,k}=native2unicode(b,'utf-16be')';
            c=fread_check(fid,4, '*uint16');
            NAme_Value{1,2,k}=native2unicode(c,'utf-16be')';
            NAme_Value{1,3,k}=char(fread_check(fid, 4, 'uint16'))';
            NAme_Value{1,4,k}=char(fread_check(fid, 4, 'uint16'))';
        end
        out.NAme_Value=NAme_Value;
    otherwise
        fclose(fid);
        error(message('images:iccread:read_dict_Type', tagname))
end
% a=data_size-16-M*N;
% c=fread_check(fid, a, 'uint8');
% out.storage=native2unicode(c,'utf-16be')';
%read_float16_Array_Type
function out = read_Array_Type(fid,offset,data_size,tagname)
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
fseek_check(fid, offset + 8, 'bof');
switch tagtype
    case 'fl16'
        A=fread_check(fid, (data_size-8)/2, '*uint16');
        Array=zeros((data_size-8)/2,1);
        for Ar=1:(data_size-8)/2
            Array(Ar,1)=floatSpRang2int(double(A(Ar,1)));
        end
    case 'fl32'
        Array=fread_check(fid, (data_size-8)/4, 'float');
    case 'fl64'
        Array=fread_check(fid, (data_size-8)/8, 'float64');
    case 'ui16'
        Array=fread_check(fid, (data_size-8)/2, 'uint16');
    otherwise
        Array=tagtype;
end
out.array=Array;
out.tagtype=tagtype;
%________________________________________
function out=read_gamut_Boundary_Description_Type(fid,offset,data_size,tagname)
fseek_check(fid, offset, 'bof'); 
out.size=data_size;
out.tagtype = char(fread_check(fid, 4, '*uint8'))';
fseek_check(fid, offset + 8, 'bof');
P=fread_check(fid, 1, 'uint16');
out.input=P;
Q=fread_check(fid, 1, 'uint16');
out.output=Q;
V=fread_check(fid, 1, 'uint32');
out.V=V;
F=fread_check(fid, 1, 'uint32');
out.F=F;
gamut_vertex_IDs=zeros(3,F);
out.data=fread_check(fid, data_size-20, 'uint8');
fseek_check(fid, offset+20, 'bof'); 
for k=1:1:F
    gamut_vertex_IDs(1,k)=fread_check(fid, 1, 'uint32');
    gamut_vertex_IDs(2,k)=fread_check(fid, 1, 'uint32');
    gamut_vertex_IDs(3,k)=fread_check(fid, 1, 'uint32');
end
out.gamut_vertex_IDs=gamut_vertex_IDs;
b=V;
gamut_PCS_coordinates=zeros(P,b);
for a=1:1:b
    gamut_PCS_coordinates(1,a)=a-1;
    for d=1:P
        gamut_PCS_coordinates(d+1,a)=fread_check(fid, 1, 'float32');
    end
end
out.gamut_PCS_coordinates=gamut_PCS_coordinates;
c=V;
gamut_device_coordinates=zeros(Q,c);
a=fread_check(fid, Q*c, 'float32')';
for d=1:c
    for e=1:Q
        gamut_device_coordinates(e,d)=a(1,3*e+d-3);
    end
end
out.gamut_device_coordinates=gamut_device_coordinates;
%-------------------------------------
%%% Read viewingConditionsType

function out = read_viewing_conditions(fid,offset,data_size, tagname)

% Clause 6.5.25 (v. 2) or 10.26 (v. 4.2)
% 0-3 'view'
% 4-7 reserved, must be 0
% 8-19 absolute XYZ for illuminant in cd/m^2
% 20-31 absolute XYZ for surround in cd/m^2
% 32-35 illuminant type

if data_size < 36
    warning(message('images:iccread:invalidTagSize1', tagname));
    out = [];
    return;
end
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(tagtype, 'view')
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''view''', '6.5.25 (v. 2), 6.5.29 (v. 4)'))
    out = [];
    return;
end
fseek_check(fid, offset + 8, 'bof');
out.IlluminantXYZ = read_xyz_number(fid);
out.SurroundXYZ = read_xyz_number(fid);
illum_idx = fread_check(fid,1,'uint32');
illuminant_table = {'Unknown','D50','D65','D93','F2',...
    'D55','A','EquiPower','F8'};
out.IlluminantType = illuminant_table{illum_idx+1};
%------------------------------------------

function out=read_specral_Viewing_condition_Type(fid,offset,data_size,...
    tagname)
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
% tagtype must be svcn
fseek_check(fid, offset + 8, 'bof');
out.size=data_size;
a=fread_check(fid, 1, 'uint32');
switch a
    case 0
        out.Colorimetric_observer_type='Custom';
    case 1
        out.Colorimetric_observer_type='CIE 1931';
    case 2
        out.Colorimetric_observer_type='CIE 1964';
    otherwise
        out.Colorimetric_observer_type='unkown';
end
% Spectral range for colorimetric observer with (N) steps
value = fread_check(fid, 3, '*uint16');
SpectralPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
SpectralPCSRange.End = uint16(floatSpRang2int(double(value(2))));
SpectralPCSRange.Step= value(3);
fseek_check(fid, offset + 20, 'bof');
out.SpectralPCSRange=SpectralPCSRange;
out.XYZ=fread_check(fid,3*SpectralPCSRange.Step , 'float');
IlluminantCode=fread_check(fid, 1, 'uint32');
switch IlluminantCode
    case 0
        out.StandardIlluminant = 'Custom';
    case 1
        out.StandardIlluminant = 'D50';
    case 2
        out.StandardIlluminant = 'D65';
    case 3
        out.StandardIlluminant = 'D93';
    case 4
        out.StandardIlluminant = 'F2';
    case 5
        out.StandardIlluminant = 'D55';
    case 6
        out.StandardIlluminant = 'A';
    case 7
        out.StandardIlluminant = 'E';
    case 8
        out.StandardIlluminant = 'F8';
    case 9
        out.StandardIlluminant = 'Black body';
    case 10
        out.StandardIlluminant = 'Daylight';
    case 11
        out.StandardIlluminant = 'B';
    case 12
        out.StandardIlluminant = 'C';
    case 13
        out.StandardIlluminant = 'F1';
    case 14
        out.StandardIlluminant = 'F3';
    case 15
        out.StandardIlluminant = 'F4';
    case 16
        out.StandardIlluminant = 'F5';
    case 17
        out.StandardIlluminant = 'F6';
    case 18
        out.StandardIlluminant = 'F7';
    case 19
        out.StandardIlluminant = 'F9';
    case 20
        out.StandardIlluminant = 'F10';
    case 21
        out.StandardIlluminant = 'F11';
    case 22
        out.StandardIlluminant = 'F12';
    otherwise
        out.StandardIlluminant = 'unknown';
end
out.temperature=fread_check(fid, 1, 'float32');
% Illuminant spectral range with (M) steps
value = fread_check(fid, 3, '*uint16');
Spectral_range.Start = uint16(floatSpRang2int(double(value(1))));
Spectral_range.End = uint16(floatSpRang2int(double(value(2))));
Spectral_range.Step= value(3);
out.Spectral_range=Spectral_range;
% o=36+SpectralPCSRange.Step*12;
% fseek_check(fid, offset + o, 'bof');
null=fread_check(fid,1 , 'uint16');
out.Vector_illuminant=fread_check(fid,Spectral_range.Step , 'float');
%Un-normalized CIEXYZ values for illuminant (with Y in cd/m2)
out.values_for_illuminant=fread_check(fid,3 , 'float');
%Un-normalized CIEXYZ values for surround (with Y in cd/m2)
out.values_for_surround=fread_check(fid,3 , 'float');
%------------------------------------------
function out=read_utlf8_Type(fid,offset,data_size,tagname)
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
out.tagtype = tagtype;
out.size=data_size;
% tagtype must be ut16 utf8 or zut8
fseek_check(fid, offset + 8, 'bof');
a=data_size-8;
switch tagtype
    case 'utf8'
        b=fread_check(fid, a, '*uint8');
        out.sig=native2unicode(b,'UTF-8')';
    case 'ut16'
        b=fread_check(fid, a, '*uint8');
        out.sig=native2unicode(b,'utf-16be')';
    case 'ZXML'
        %CM= dec2bin(fread_check(fid, a, 'uint8')',8)=='1';
        CM= fread_check(fid, a, 'uint8')';
        %     if CM(1,13)==1
        %        dictid=dec2bin(fread_check(fid, 4, 'uint8'))=='1';
        %       a=a-6;
        %  else
        %     dictid=dec2bin(fread_check(fid, 4, 'uint8'))=='1';
        %    a=a-2;
        % end
        out.CM=CM;
        %     out=huffmandeco(c);
        %    case 'zut8'
    otherwise
        b=fread_check(fid, a, '*uint8');
        out.sig=char(b)';
end
function out=read_tag_Struct_type(fid,offset,data_size,element_Name)
fseek_check(fid, offset, 'bof');
out.data=fread_check(fid, data_size, '*uint8');
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
% tagtype must be tstr
fseek_check(fid, offset + 8, 'bof');
Struct_Type_Identifier=char(fread_check(fid, 4, '*uint8'))';
out.Struct_Type_Identifier=Struct_Type_Identifier;
% Number of tag elements N in structure
NumN=fread_check(fid, 1, '*uint32');
tagsruct=cell(NumN,3);
out.NumN=NumN;
switch Struct_Type_Identifier
    case 'brdf'
        % 12.2.1
        for k=1:NumN
            % Tag element 1 signature
            fseek_check(fid, offset + 4+k*12, 'bof');
            element_Name=char(fread_check(fid, 4, '*uint8'))';
            tagsruct{k,1}=element_Name;
            str=element_Name;
            old = ' ';
            new = '';
            element_Name = replace(str,old,new);
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            tagsruct{k,3}=namevalue_size;
            fseek_check(fid, offset+namevalue_offset, 'bof');
            switch element_Name
                case {'type','func'}
                    a.name=char(fread_check(fid, 4, '*uint8'))';
                    fseek_check(fid, offset+namevalue_offset+8, 'bof');
                    a.colortype=char(fread_check(fid, 4, '*uint8'))';
                    tagsruct{k,2}=a;
                case 'nump'
                    b.name=char(fread_check(fid, 4, '*uint8'))';
                    fseek_check(fid, offset+namevalue_offset+8, 'bof');
                    b.number=fread_check(fid, 1, 'uint16');
                    tagsruct{k,2}=b;
                case 'xfrm'
                    c=offset+namevalue_offset;
                    tagsruct{k,2}=read_mulit_Process_Elements_Type(fid,c,namevalue_size);
                otherwise 
                    a=namevalue_size;
            end
        end
        out.brdf=tagsruct;
    case 'cinf'
        % 12.2.2
        for k=1:NumN
            % Tag element 1 signature
            element_Name=char(fread_check(fid, 4, '*uint8'))';
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            fseek_check(fid, offset+namevalue_offset, 'bof');
            switch element_Name
                case 'name'
                case 'lcnm'
                case 'pcs'
                case 'spec'
            end
            fseek_check(fid, offset+k*12+16, 'bof');
        end
    case 'cept'
        % 12.2.3
        for k=1:NumN
            % Tag element 1 signature
            element_Name=char(fread_check(fid, 4, '*uint8'))';
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            fseek_check(fid, offset+namevalue_offset, 'bof');
            switch element_Name
                case {'bXYZ','gXYZ','rXYZ','wXYZ','mwpc','mbpc','awpc'}
                    cept.(element_Name).name=char(fread_check(fid, 4, '*uint8'))';
                    fseek_check(fid, offset+namevalue_offset+8, 'bof');
                    a=(namevalue_size-8)/4;
                    if a==2
                        cept.(element_Name).data=fread_check(fid,a, 'float');
                        cept.(element_Name).data(3,1)=1-cept.(element_Name).data(1,1)-cept.(element_Name).data(2,1);
                    else
                        cept.(element_Name).data=fread_check(fid,a, 'float');
                    end
                case 'func'
                    cept.(element_Name).name=char(fread_check(fid, 4, '*uint8'))';
                    fseek_check(fid, offset+namevalue_offset+8, 'bof');
                    N=fread_check(fid, 1, 'uint16');
                    fseek_check(fid, offset+namevalue_offset+12, 'bof');
                    cept.(element_Name).break_point=fread_check(fid, N-1, 'float');
                    seg=char(fread_check(fid, 4, '*uint8'))';
                    switch seg
                        case 'parf'
                            fseek_check(fid, offset+namevalue_offset+16+4*N, 'bof');
                            type=fread_check(fid, 1, 'uint16');
                            cept.(element_Name).(seg).Param=char(fread_check(fid, 4, '*uint8'))';
                        case 'samf'
                            fseek_check(fid, offset+namevalue_offset+16+4*N, 'bof');
                            countN=fread_check(fid, 1, 'uint32');
                            cept.(element_Name).(seg)=fread_check(fid, countN, 'uint32');
                        otherwise
                    end
                    
                case 'lmat'
                    cept.(element_Name)=namevalue_size;
                case {'wlum','ibkg','srnd','ailm','mwpl','mbpl','awlm'}
                    cept.(element_Name).name=char(fread_check(fid, 4, '*uint8'))';
                    fseek_check(fid, offset+namevalue_offset+8, 'bof');
                    cept.(element_Name).data=fread_check(fid,1, 'float');
                case 'eRng'
                    cept.(element_Name).name=char(fread_check(fid, 4, '*uint8'))';
                    fseek_check(fid, offset+namevalue_offset+8, 'bof');
                    cept.(element_Name).min=fread_check(fid,1, 'float');
                    cept.(element_Name).max=fread_check(fid,1, 'float');
                case 'bits'
                    cept.(element_Name).name=char(fread_check(fid, 4, '*uint8'))';
                    fseek_check(fid, offset+namevalue_offset+8, 'bof');
                    a=namevalue_size-8;
                    cept.(element_Name).data=fread_check(fid,a, 'uint8');
                case 'imst'
                    cept.(element_Name).name=char(fread_check(fid, 4, '*uint8'))';
                    fseek_check(fid, offset+namevalue_offset+8, 'bof');
                    cept.(element_Name).type=char(fread_check(fid, 4, '*uint8'))';
                case 'flar'
                    cept.(element_Name)=namevalue_size;
                case 'lrng'
                    cept.(element_Name)=namevalue_size;
                otherwise
                    cept.(element_Name)=(element_Name);
            end
            cept.table.(element_Name)=(element_Name);
            fseek_check(fid, offset+k*12+16, 'bof');
        end
        out.cept=cept;
    case 'meas'
        % 12.2.4
        for k=1:NumN
            % Tag element 1 signature
            element_Name=char(fread_check(fid, 4, '*uint8'))';
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            fseek_check(fid, offset+namevalue_offset, 'bof');
            switch element_Name
                case 'mbak'
                    meas.(element_Name)=namevalue_size;
                case 'mflr'
                    meas.(element_Name)=namevalue_size;
                case 'mgeo'
                    meas.(element_Name)=namevalue_size;
                case 'mill'
                    meas.(element_Name)=namevalue_size;
                case 'miwr'
                    meas.(element_Name)=namevalue_size;
                case 'mmod'
                    meas.(element_Name)=namevalue_size;
                otherwise
                    meas.(element_Name)=namevalue_size;
            end
            fseek_check(fid, offset+k*12+16, 'bof');
        end
        out.meas=meas;
    case 'nmcl'
        % 12.2.5
        for k=1:NumN
            % Tag element 1 signature
            element_Name=char(fread_check(fid, 4, '*uint8'))';
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            fseek_check(fid, offset+namevalue_offset, 'bof');
            switch element_Name
                case 'bcol'
                case 'bcpr'
                case 'bspc'
                case 'name'
                case 'lcnm'
                case 'dev'
                case 'nmap'
                case 'pcs'
                case 'spec'
                case 'spcb'
                case 'spcg'
                case 'tint'
            end
            fseek_check(fid, offset+k*12+16, 'bof');
        end
    case 'pinf'
        % 12.2.6
        for k=1:NumN
            % Tag element 1 signature
            element_Name=char(fread_check(fid, 4, '*uint8'))';
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            fseek_check(fid, offset+namevalue_offset, 'bof');
            switch element_Name
                case 'attr'
                case 'pdsc'
                case 'pid'
                case 'dmnd'
                case 'dmdd'
                case 'dmns'
                case 'mod'
                case 'rtrn'
                case 'tech'
            end
            fseek_check(fid, offset+k*12+16, 'bof');
        end
    case 'tnt0'
        % 12.2.7
        for k=1:NumN
            % Tag element 1 signature
            element_Name=char(fread_check(fid, 4, '*uint8'))';
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            fseek_check(fid, offset+namevalue_offset, 'bof');
            switch element_Name
                case 'dev'
                case 'pcs'
                case 'spec'
                case 'spcb'
                case 'spcg'
            end
            fseek_check(fid, offset+k*12+16, 'bof');
        end
end
function out=read_tag_Array_Type(fid,offset,data_size,tagname)
fseek_check(fid, offset, 'bof');
Array.size=data_size;
Array.tagtype = char(fread_check(fid, 4, '*uint8'))';
% tagtype must be tary
fseek_check(fid, offset + 8, 'bof');
Array.IDen=char(fread_check(fid, 4, '*uint8'))';
N=fread_check(fid, 1, 'uint32');
sig=cell(N,1);
Array.N=N;
switch Array.IDen
    case 'utf8'
        for k=1:1:N
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            fseek_check(fid, offset+namevalue_offset, 'bof');
            a=fread_check(fid, namevalue_size, '*uint8');
            sig{k,1}=native2unicode(a,'UTF-8')';
            fseek_check(fid, offset+16+k*8, 'bof');
        end
    case 'nmcl'
        for k=1:1:N
            namevalue_offset=fread_check(fid,1, 'uint32');
            namevalue_size=fread_check(fid,1, 'uint32');
            fseek_check(fid, offset+namevalue_offset, 'bof');
            a=fread_check(fid, namevalue_size, '*uint8');
            sig{k,1}=char(a);
            fseek_check(fid, offset+16+k*8, 'bof');
        end
end
Array.dict=sig;
out=Array;
%-------------------------------------------
%%% read_named_color_type

function out = read_named_color_type(fid, offset, ~, pcs, tagname)

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

fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(tagtype, 'ncl2')
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''ncl2''', '10.14 (v. 4.2)'))
    out = [];
    return;
end

out = struct('VendorFlag', [], ...
    'DeviceCoordinates', [], ...
    'Prefix', [], ...
    'Suffix', [], ...
    'NameTable', []);
fseek_check(fid, offset + 8, 'bof');
out.VendorFlag = dec2hex(fread_check(fid, 1, '*uint32'));
n = fread_check(fid, 1, 'uint32');
m = fread_check(fid, 1, 'uint32');
out.DeviceCoordinates = m;
prefix = fread_check(fid, 32, '*uint8')';
out.Prefix = trim_string(prefix);
suffix = fread_check(fid, 32, '*uint8')';
out.Suffix = trim_string(suffix);
if m > 0
    out.NameTable = cell(n, 3);
else
    out.NameTable = cell(n, 2); % no device coordinates
end
for i = 1 : n
    name = fread_check(fid, 32, '*uint8')';
    out.NameTable{i, 1} = trim_string(name);
    pcs16 = fread_check(fid, 3, '*uint16')';
    out.NameTable{i, 2} = encode_color(pcs16, pcs, 'uint16', 'double');
    if m > 0
        dev16 = fread_check(fid, m, '*uint16')';
        out.NameTable{i, 3} = encode_color(dev16, ...
            'color_n', 'uint16', 'double');
    end
end

%------------------------------------------
%%% read_profile_sequence_type

function out = read_profile_sequence_type(fid, offset, data_size, ...
    version, tagname)

% Clause 10.16 (v. 4.2)
% 0-3   'pseq'
% 4-7   reserved, must be 0
% 8-11  count of profile description structures
% 12-   profile description structures

if data_size < 12
    warning(message('images:iccread:invalidTagSize1', tagname));
    out = [];
    return;
end
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(tagtype, 'pseq')
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''pseq''', '10.16 (v. 4.2)'))
    out = [];
    return;
end
fseek_check(fid, offset + 8, 'bof');
n = fread_check(fid, 1, 'uint32');

out = struct('DeviceManufacturer', {}, ...
    'DeviceModel', {}, ...
    'Attributes', {}, ...
    'IsTransparency', {}, ...
    'IsMatte', {}, ...
    'IsNegative', {}, ...
    'IsBlackandWhite', {}, ...
    'Technology', {}, ...
    'DeviceMfgDesc', {}, ...
    'DeviceModelDesc', {});
technologies = get_technologies;

for p = 1:n
    out(p).DeviceManufacturer = char(fread_check(fid, 4, '*uint8'))';
    out(p).DeviceModel = char(fread_check(fid, 4, '*uint8'))';
    fseek_check(fid, 4, 'cof');
    out(p).Attributes = fread_check(fid, 1, 'uint32')';
    out(p).IsTransparency = bitget(out(p).Attributes, 1) == 1;
    out(p).IsMatte = bitget(out(p).Attributes, 2) == 1;
    out(p).IsNegative = bitget(out(p).Attributes, 3) == 1;
    out(p).IsBlackandWhite = bitget(out(p).Attributes, 4) == 1;
    techsig = char(fread_check(fid, 4, '*uint8'))';
    if strcmp(techsig, char(uint8([0 0 0 0])))
        out(p).Technology = 'Unspecified';
    else
        idx = strmatch(techsig, technologies(:, 1), 'exact');
        if isempty(idx)
            warning(message('images:iccread:invalidTechnologySignature', tagname))
            out(p).Technology = techsig;
        else
            out(p).Technology  = technologies{idx, 2};
        end
    end
    current = ftell(fid);
    if version <= 2
        out(p).DeviceMfgDesc ...
            = read_text_description_type(fid, current, 0, 'DeviceMfgDesc');
        if isempty(out(p).DeviceMfgDesc) % try v. 4 type
            out(p).DeviceMfgDesc ...
                = read_unicode_type(fid, current, 0, 'DeviceMfgDesc');
        end
    else
        out(p).DeviceMfgDesc ...
            = read_unicode_type(fid, current, 0, 'DeviceMfgDesc');
        if isempty(out(p).DeviceMfgDesc) % try v. 2 type
            out(p).DeviceMfgDesc ...
                = read_text_description_type(fid, current, 0, 'DeviceMfgDesc');
        end
    end
    if isempty(out(p).DeviceMfgDesc)
        out = [];
        return;
    elseif isempty(out(p).DeviceMfgDesc.String)
        out(p).DeviceMfgDesc.String = 'Unavailable';
    end
    
    current = ftell(fid);
    if version <= 2
        out(p).DeviceModelDesc ...
            = read_text_description_type(fid, current, 0, 'DeviceModelDesc');
        if isempty(out(p).DeviceModelDesc) % try v. 4 type
            out(p).DeviceModelDesc = ...
                read_unicode_type(fid, current, 0, 'DeviceModelDesc');
        end
    else
        out(p).DeviceModelDesc ...
            = read_unicode_type(fid, current, 0, 'DeviceModelDesc');
        if isempty(out(p).DeviceModelDesc) % try v. 2 type
            out(p).DeviceModelDesc = ...
                read_text_description_type(fid, current, 0, 'DeviceModelDesc');
        end
    end
    if isempty(out(p).DeviceModelDesc)
        out = [];
        return;
    elseif isempty(out(p).DeviceModelDesc.String)
        out(p).DeviceModelDesc.String = 'Unavailable';
    end
    
end

%------------------------------------------
%%% read_response_curve_set16_type

function out = read_response_curve_set16_type(fid, offset, data_size, ...
    tagname)

% Clause 10.17 (v. 4.2)
% 0-3    'rcs2'
% 4-7    reserved, must be 0
% 8-9    number of channels n
% 10-11  number of measurement types m
% 12-(11+4m)    array of offsets
% (12+4m)-end   m response-curve structures

if data_size < 12
    warning(message('images:iccread:invalidTagSize1', tagname));
    out = [];
    return;
end
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(tagtype, 'rcs2')
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''rcs2''', '10.17 (v. 4.2)'))
    out = [];
    return;
end
fseek_check(fid, offset + 8, 'bof');
numchan = fread_check(fid, 1, 'uint16');
numtypes = fread_check(fid, 1, 'uint16');
soffset = zeros(1, numtypes);
for i = 1 : numtypes
    soffset(i) = fread_check(fid, 1, 'uint32');
end

% response-curve structure
% 0-3             measurement-type signature
% 4-(3+4n)        number of measurements for each channel
% (4+4n)-(3+16n)  XYZ of solid-colorant patches
% (4+12n)-end     n response arrays

emptyInitializer = cell(1,numtypes);
out = struct('MeasurementCode', emptyInitializer, ...
    'MeasurementType', emptyInitializer, ...
    'SolidXYZs', emptyInitializer, ...
    'ResponseArray', emptyInitializer);

for i = 1 : numtypes
    fseek(fid, offset + soffset(i), 'bof');
    out(i).MeasurementCode = char(fread_check(fid, 4, '*uint8'))';
    switch out(i).MeasurementCode
        case 'StaA'
            out(i).MeasurementType = 'Status A';
        case 'StaE'
            out(i).MeasurementType = 'Status E';
        case 'StaI'
            out(i).MeasurementType = 'Status I';
        case 'StaT'
            out(i).MeasurementType = 'Status T';
        case 'StaM'
            out(i).MeasurementType = 'Status M';
        case 'DN  '
            out(i).MeasurementType = 'DIN E, no polarizing filter';
        case 'DN P'
            out(i).MeasurementType = 'DIN E, with polarizing filter';
        case 'DNN '
            out(i).MeasurementType = 'DIN I, no polarizing filter';
        case 'DNNP'
            out(i).MeasurementType = 'DIN I, with polarizing filter';
        otherwise
            out(i).MeasurementType = 'unknown';
    end
    
    nmeas = zeros(1, numchan);
    for j = 1 : numchan
        nmeas(j) = fread_check(fid, 1, 'uint32');
    end
    for j  = 1 : numchan
        out(i).SolidXYZs(j, :) = read_xyz_number(fid);
    end
    for j = 1 : numchan
        out(i).ResponseArray{j} = zeros(nmeas(j), 2);
        for k = 1 : nmeas(j)
            out(i).ResponseArray{j}(k, 1) = ...
                fread_check(fid, 1, 'uint16') / 65535.0;
            fseek(fid, 2, 'cof');
            out(i).ResponseArray{j}(k, 2) = ...
                fread_check(fid, 1, 'uint32') / 65536.0;
        end
    end
end

%------------------------------------------
%%% read_signature_type

function out = read_signature_type(fid, offset, data_size, tagname)

% Clause 10.19 (v. 4.2)
% 0-3   'sig '
% 4-7   reserved, must be 0
% 8-11  four-byte signature

if data_size < 12
    warning(message('images:iccread:invalidTagSize1', tagname));
    out = [];
    return;
end
fseek_check(fid, offset, 'bof');
typesig = char(fread_check(fid, 4, '*uint8'))';
if strcmp(typesig, 'sig ')
    fseek_check(fid, offset + 8, 'bof');
    techsig = char(fread_check(fid, 4, '*uint8'))';
    if strmatch(techsig, char(uint8([0 0 0 0])))
        out = 'Unspecified';
    else
        technologies = get_technologies;
        idx = strmatch(techsig, technologies(:, 1), 'exact');
        if isempty(idx)
            warning(message('images:iccread:invalidTechnologySignature', tagname))
            out = [];
        else
            out  = technologies{idx, 2};
        end
    end
else
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''sig ''', '10.19 (v. 4.2)'))
    out = [];
end


%------------------------------------------
%%% read_text_description_type

function out = read_text_description_type(fid, offset, data_size, tagname)

% Clause 6.5.17 (v. 2 only; replaced by Unicode in v. 4)
% 0-3   'desc'
% 4-7   reserved, must be 0
% 8-11  ASCII invariant description count, including terminating NULL
% 12-   ASCII invariant description
% followed by optional Unicode and ScriptCode descriptions, which we
% preserve.

% Note:  Since this function can be called for a textDescriptionType
% embedded in another tag (profileSequenceDescType), the
% data_size field may be invalid -- e.g., zero.  Therefore,
% there is no check for sufficient size (= 12 bytes).

% Check for desc signature
fseek_check(fid, offset, 'bof');
chartype = char(fread_check(fid, 4, '*uint8'))';
if strcmp(chartype, 'desc')
    % read ASCII string
    fseek_check(fid, offset + 8, 'bof');
    count = fread_check(fid, 1, 'uint32'); % ASCII count
    % count includes the trailing NULL, which we don't need.
    % Note that profiles have been found in which the expected
    % trailing NULL is not present, in which case count is 0.
    out.String = char(fread_check(fid, count, '*uint8'))';
    if ~isempty(out.String)
        % Remove the trailing NULL.
        out.String = out.String(1:end-1);
    end
    
    % read or construct optional data
    if data_size > count + 12       % assume data_size correct
        out.Optional = fread_check(fid, data_size - 12 - count, '*uint8')';
    elseif data_size == count + 12  % no optional data
        out.Optional = uint8(zeros(1, 78)); % supply minimal data
    else                            % improper data_size; investigate
        % read Unicode string
        out.Optional(1:8) = fread_check(fid, 8, '*uint8')';
        unicount = double(out.Optional(5:8)); % Unicode count
        ucount = bitshift(unicount(1), 24) + bitshift(unicount(2), 16) + ...
            bitshift(unicount(3), 8) + unicount(4);
        if ucount > 0
            out.Optional(9:8+2*ucount) = fread_check(fid, 2 * ucount, '*uint8')';
        end
        
        % read ScriptCode string
        out.Optional(9+2*ucount:78+2*ucount) = ...
            fread_check(fid, 70, '*uint8')';
    end
    % optional Unicode or ScriptCode data, saved but not interpreted
    
else
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''desc''', '6.5.17'))
    out = [];
end

%------------------------------------------
%%% read_unicode_type

function out = read_unicode_type(fid, offset, ~, tagname)

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

% Note:  Since this function can be called for a multiLocalized-
% UnicodeType embedded in another tag (profileSequenceDescType),
% the data_size field may be invalid -- e.g., zero.  Therefore,
% there is no check for sufficient size (= 16 bytes).

% Check for mluc signature
fseek_check(fid, offset, 'bof');
chartype = char(fread_check(fid, 4, '*uint8'))';
if strcmp(chartype, 'mluc') % New v. 4 type
    out = read_mluc(fid, offset);
else
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''mluc''', '6.5.14'))
    out = [];
end


%------------------------------------------
%%% read_text_type

function out = read_text_type(fid, offset, data_size, tagname)

% Clause 6.5.18 (v. 2) or 10.20 (v. 4.2)
% 0-3 'text'
% 4-7 reserved, must be 0
% 8-  string of (data_size - 8) 7-bit ASCII characters, including NULL

if data_size < 8
    warning(message('images:iccread:invalidTagSize1', tagname));
    out = [];
    return;
end
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(tagtype, 'text')
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''text''', '6.5.18 (v. 2), 6.5.22 (v. 4)'))
    out = [];
    return;
end
fseek_check(fid, offset + 8, 'bof');
out = char(fread_check(fid, data_size-9, '*uint8'))';

%------------------------------------------
%%% read_date_time_type

function out = read_date_time_type(fid, offset, data_size, tagname)

% Clause 6.5.5 (v. 2) or 10.7 (v. 4.2)
% 0-3   'dtim'
% 4-7   reserved, must be 0
% 8-19  DateTimeNumber

if data_size < 20
    warning(message('images:iccread:invalidTagSize1', tagname));
    out = [];
    return;
end
fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(tagtype, 'dtim')
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''dtim''', '6.5.5 (v. 2), 6.5.7 (v. 4)'))
    out = [];
    return;
end
fseek_check(fid, offset + 8, 'bof');
out = read_date_time_number(fid);

%------------------------------------------
%%% read_crd_info_type

function out = read_crd_info_type(fid, offset, data_size, tagname)

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

if data_size < 12
    warning(message('images:iccread:invalidTagSize1', tagname));
    out = [];
    return;
end

fseek_check(fid, offset, 'bof');
tagtype = char(fread_check(fid, 4, '*uint8'))';
if ~strcmp(tagtype, 'crdi')
    warning(message('images:iccread:invalidTagTypeWithReference', tagname, '''crdi''', '6.5.2 (v. 2), 6.5.4 (v. 4)'))
    out = [];
    return;
end
fseek_check(fid, offset + 8, 'bof');
count = fread_check(fid, 1, 'uint32');
name = char(fread_check(fid, count, '*uint8'))';
out.PostScriptProductName = name(1:end-1);
out.RenderingIntentCRDNames = cell(4,1);
for k = 1:4
    count = fread_check(fid, 1, 'uint32');
    name = char(fread_check(fid, count, '*uint8'))';
    out.RenderingIntentCRDNames{k} = name(1:end-1);
end

%------------------------------------------
%%% read_date_time_number

function out = read_date_time_number(fid)

% Clause 5.3.1 (v. 2) and 5.1.1 (v. 4.2)
out = fread_check(fid, 6, 'uint16');

%---------------------------------------------
%%% read_mluc

function mluc = read_mluc(fid, offset)
%READ_MLUC Read multiLocalizedUnicodeType tag from ICC profile.
%   MLUC = READ_MLUC(FID, OFFSET) reads a multiLocalizedUnicodeType tag
%   located at OFFSET (in bytes from the beginning of the file) using the
%   file identifier FID.  MLUC is a structure array containing the fields:
%
%      String       Unicode characters stored as a MATLAB char array.
%      LanguageCode ISO-639 language code.
%      CountryCode  ISO-3166 country code.
%
%   The number of elements in the structure array is the number of names
%   stored in the tag.
%
%   See section 6.5.12 of the ICC specification "File Format for Color
%   Profiles," version 4.1.0.

% Skip past first four bytes ('mluc') and second four bytes (all 0).
fseek_check(fid, offset + 8, 'bof');

num_names = fread_check(fid, 1, 'uint32');
fread_check(fid, 1, 'uint32');

% Initialize the output structure to fix the desired field order.
emptyInitializer = cell(1, num_names);
mluc = struct('String', emptyInitializer, ...
    'LanguageCode', emptyInitializer, ...
    'CountryCode', emptyInitializer);
temp = struct('NameLength', emptyInitializer, ...
    'NameOffset', emptyInitializer);

for k = 1:num_names
    b=fread_check(fid, 2, '*uint8');
    mluc(k).LanguageCode = native2unicode(b,'UTF-8')';
    b=fread_check(fid, 2, '*uint8');
    mluc(k).CountryCode  = native2unicode(b,'UTF-8')';
    
    % Name length and offset are using for reading in the Unicode
    % characters, but they aren't needed in the output structure mluc.
    temp(k).NameLength = fread_check(fid, 1, 'uint32');
    temp(k).NameOffset = fread_check(fid, 1, 'uint32');
end

for k = 1:num_names
    fseek_check(fid, offset + temp(k).NameOffset, 'bof');
    
    str = fread_check(fid, temp(k).NameLength, '*uint8');
    str = reshape(str, [1 numel(str)]);
    mluc(k).String = native2unicode(str, 'utf-16be');
end

%------------------------------
%%% trim_string

function string = trim_string(bytes)

if ~strcmp(class(bytes), 'uint8')
    error(message('images:iccread:invalidInputData'))
end
endbyte = strfind(bytes, 0);
string = char(bytes(1 : endbyte - 1));

%------------------------------
%%% fseek_check

function fseek_check(fid, n, origin)
if fseek(fid, n, origin) < 0
    pos = ftell(fid);
    fclose(fid);
    error(message('images:iccread:fseekFailed', n, pos))
end

%------------------------------
%%% fread_check

function out = fread_check(fid, n, precision)

[out,count] = fread(fid, n, precision);
if count ~= n
    pos = ftell(fid) - count;
    fclose(fid);
    error(message('images:iccread:fileReadFailed', n, pos))
end

function res=floatSpRang2int(shortfloat )
% 将16位的浮点数转换为整数
e=bitshift(shortfloat,1);
e=bitshift(e,-11);
t=bitand(shortfloat,1023);%1023即为二进制后10位为1
res=2^(e-15)*(1+2^(-10)*t);

function out = read_sparse_Matrix_Type(fid,offset,data_size,tagname)
fseek_check(fid, offset, 'bof');
out.tagtype = char(fread_check(fid, 4, '*uint8'))';
fseek_check(fid, offset+8, 'bof');
out.Q=fread_check(fid, 1, 'uint16');
type=fread_check(fid, 1, 'uint16');
out.numLUT=fread_check(fid, 1, 'uint32');
out.R=fread_check(fid, 1, 'uint16');
out.C=fread_check(fid, 1, 'uint16');
out.Start_R=fread_check(fid, out.R, 'uint16');
numN=fread_check(fid, 1, 'uint16');
out.array=fread_check(fid, numN, 'uint16');
switch type
    case 1
        type='sparsematrixUInt8';
    case 2
        type='sparseMatrixUInt16';
    case 3
        type='sparseMatrixFloat16';
    case 4
        type='sparseMatrixFloat32';
end

function out=reaad_Spectral_data_Type(fid,offset,data_size,tagname)
fseek_check(fid, offset, 'bof');
out.zise=data_size;
out.tagtype = char(fread_check(fid, 4, '*uint8'))';
fseek_check(fid, offset+8, 'bof');
a=char(fread_check(fid,2, '*uint8'))';
b=fread_check(fid,1, '*uint16');
out.b=b;
c=dec2hex(b,4);
out.ColorSignature=strcat(a,c);
value = fread_check(fid, 3, '*uint16');
out.SpectralPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
out.SpectralPCSRange.End = uint16(floatSpRang2int(double(value(2))));
out.SpectralPCSRange.Step= value(3);

function out=read_mulit_Process_Elements_Type(fid,offset,data_size,tagname)
% fseek_check(fid, offset, 'bof');  
% out.data=fread_check(fid, data_size, '*uint8')';
fseek_check(fid, offset, 'bof'); 
% out.data_size=data_size;
tagtype = char(fread_check(fid, 4, '*uint8'))';
out.tagtype=tagtype;
% tagtype must be mpet
fseek_check(fid, offset+8, 'bof');
out.P=fread_check(fid, 1, 'uint16');
out.Q=fread_check(fid, 1, 'uint16');
out.N=fread_check(fid, 1, 'uint32');
func=cell(out.N,3);
for k=1:out.N
    namevalue_offset=fread_check(fid,1, 'uint32');
    namevalue_size=fread_check(fid,1, 'uint32');
    func{k,3}=namevalue_size;
    fseek_check(fid, offset+namevalue_offset, 'bof');
    name=char(fread_check(fid, 4, '*uint8'))';
    func{k,1}=name;
    switch name
        case 'calc'
            func{k,2}=read_calc_element(fid, offset+namevalue_offset);
        case 'cvst'
            func{k,2}=read_cvst_element(fid, offset+namevalue_offset, 'bof');
        case 'clut'
            func{k,2}=read_clut_element(fid, offset+namevalue_offset);
        case 'eclt'
            func{k,2}=read_eclt_element(fid, offset+namevalue_offset);
        case 'emtx'
            func{k,2}=read_emtx_element(fid, offset+namevalue_offset);
        case 'eobs'
            func{k,2}=read_eobs_element(fid, offset+namevalue_offset);
        case 'xclt'
            func{k,2}=read_xclt_element(fid, offset+namevalue_offset);
        case 'iemx'
            func{k,2}=read_iemx_element(fid, offset+namevalue_offset);
        case 'JtoX'
            func{k,2}=read_JtoX_element(fid,offset+namevalue_offset);
        case 'matf'
            func{k,2}=read_matf_element(fid, offset+namevalue_offset, 'bof');
        case 'smet'
            func{k,2}=read_smet_element(fid, offset+namevalue_offset);
        case 'rclt'
            func{k,2}=read_rclt_element(fid, offset+namevalue_offset);
        case 'robs'
            func{k,2}=read_robs_element(fid, offset+namevalue_offset);
        case 'tint'
            func{k,2}=read_tint_element(fid, namevalue_offset, 'bof',namevalue_size);
        case 'XtoJ'
            func{k,2}=read_JtoX_element(fid,offset+namevalue_offset);
            %            case 'bACS'
            %            case 'eACS'
        otherwise
            func{k,2}=func;
    end
    fseek_check(fid, offset+16+k*8, 'bof');
end
out. func= func;

function out=read_matf_element(fid, offset, cha)
fseek_check(fid, offset+8, cha);
matf.numP=fread_check(fid, 1, 'uint16');
matf.numQ=fread_check(fid, 1, 'uint16');
elements=fread_check(fid, (matf.numP+1)*matf.numQ, 'float');
Matrix_elements=zeros(matf.numQ,matf.numP);
for c=1:matf.numQ
    for d=1:matf.numP
        Matrix_elements(c,d)=elements(c*matf.numP-matf.numP+d,1);
    end
end
matf.Matrix_elements=Matrix_elements;
size_e = size(Matrix_elements, 1);
matf.e=elements(size(elements,1) - size_e + 1: size(elements, 1),1);
out=matf;

function out=read_cvst_element(fid, offset, cha)
fseek_check(fid, offset+8, cha);
cvst.numP=fread_check(fid, 1, 'uint16');
cvst.numQ=fread_check(fid, 1, 'uint16');
a=fread_check(fid, 2*cvst.numP, 'uint32');
sample=cell(cvst.numP,2);
for b=1:cvst.numP
    fseek_check(fid, offset+a(2*b-1,1), 'bof');
    curvename=char(fread_check(fid, 4, 'uint8')');
    sample{b,1}=curvename;
    fseek_check(fid, offset+a(2*b-1,1)+8, 'bof');
    switch curvename
        case 'sngf'
            % Number of Data entries(N)
            sngf.N=fread_check(fid, 1, 'uint32');
            % Input value of first entry(F)
            sngf.F=fread_check(fid, 1, 'float');
            % Input value of last entry(L)
            sngf.L=fread_check(fid, 1, 'float');
            % Lookup extension type(E)
            sngf.E=fread_check(fid, 1, 'uint16');
            % Data encoding type
            type=fread_check(fid, 1, 'uint16');
            % valueEncodingType
            switch type
                case 0
                    sngf.type='float32';
                case 1
                    sngf.type='float16';
                case 2
                    sngf.type='uint16';
                case 3
                    sngf.type='uint32';
            end
            sample{b,2}=sngf;
        case 'curf'
%             fseek_check(fid, offset+a(2*b-1,1)+8, 'bof');
            % Number of segment(s) (N)
            curf.numN= fread_check(fid, 1, 'uint16');
            fseek_check(fid, offset+a(2*b-1,1)+12, 'bof');
            % N-1 Break-Points
            if curf.numN==1
            else
                curf.Break_Points= fread_check(fid, curf.numN-1, 'float');
            end
            Parameters=cell(curf.numN,4);
            for i=1:curf.numN
                type=char(fread_check(fid, 4, 'uint8')');
                Parameters{i,1}=type;
                null=fread_check(fid, 4, 'uint8');
                switch type
                    case 'parf'
                        Encoded_type=fread_check(fid, 1, 'uint16');
                        null=fread_check(fid, 1, 'uint16');
                        Parameters{i,2}=Encoded_type;
                        switch Encoded_type
                            case 0
                                Parameters{i,3}=fread_check(fid, 4, 'float')';
                            otherwise
                                Parameters{i,3}=fread_check(fid, 5, 'float')';
                        end
                    case 'samf'
                        N=fread_check(fid, 1, 'uint32');
                        Parameters{i,2}=N;
                        Parameters{i,3}=fread_check(fid, N, 'float');
                end
            end
            curf.Parameters=Parameters;
            sample{b,2}=curf;
    end
end
cvst.sample=sample;
out=cvst;

function out=read_tint_element(fid, offset, cha,data_size)
fseek_check(fid, offset, cha);
tint.element_type=char(fread_check(fid, 4, 'uint8')');
fseek_check(fid, offset+8, cha);
tint.numP=fread_check(fid, 1, 'uint16');
tint.numQ=fread_check(fid, 1, 'uint16');
% if data_size==950552
    TintEncodingType=0;
% else
%     TintEncodingType=fread_check(fid, 4, 'uint8');
% end
fseek_check(fid, offset+20, 'bof');
%             value = fread_check(fid, 3, '*uint16');
%             robs.SpectralPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
tint.type=TintEncodingType;
switch TintEncodingType
    case 1
        %  float16
        numb=(data_size-20)/2;
        a = fread_check(fid, numb, '*uint16');
        value=uint16(floatSpRang2int(double(a)));
    case 2
        %  uint16
        numb=(data_size-20)/2;
        value = fread_check(fid, numb, '*uint16');
    case 3
        %  uint8
        numb=(data_size-20);
        value = fread_check(fid, numb, '*uint8');
    case 0
        %  float32
        numb=(data_size-20)/4;
        value = fread_check(fid, numb, 'float');
    otherwise
        value=1;
end
null=find(value<0.00000001);
size_null=size(null);
for i=1:size_null(1,1)
    value(null,1)=0;
end
tint.Arrart=value;
out=tint;

function out=read_clut_element(fid, offset)
fseek_check(fid, offset+8, 'bof');
clut.numP=fread_check(fid, 1, 'uint16');
clut.numQ=fread_check(fid, 1, 'uint16');
clut.num_grid=fread_check(fid, 16, 'uint8');
num=clut.numQ;
for i=1:clut.numP
    num=num*clut.num_grid(i,1);
end
clut.lut=fread_check(fid, num, 'float32');
out=clut;

function out=read_JtoX_element(fid,offset)
fseek_check(fid, offset+8, 'bof');
JtoX.numP=fread_check(fid, 1, 'uint16');
JtoX.numQ=fread_check(fid, 1, 'uint16');
xyz=fread_check(fid, 12, 'uint8');
JtoX.White_XYZ= uint2float_xyz_number(xyz);
value=fread_check(fid, 5, 'float');
JtoX.Luminance=value(1,1);
JtoX.Background_luminance=value(2,1);
JtoX.Impact=value(3,1);
JtoX.Chromatic=value(4,1);
JtoX.Adaptation=value(5,1);
out=JtoX;

function out=read_calc_element(fid,offset)
fseek_check(fid, offset+8, 'bof');
calc.numP=fread_check(fid, 1, 'uint16');
calc.numQ=fread_check(fid, 1, 'uint16');
calc.numE=fread_check(fid, 1, 'uint32');
namevalue_Main_offset_size=fread_check(fid,2, 'uint32');
calc.main_size=namevalue_Main_offset_size(2,1);
namevalue_SUB_offset_size=fread_check(fid,calc.numE*2, 'uint32');

fseek_check(fid, offset+namevalue_Main_offset_size(1,1), 'bof');
calc.func=char(fread_check(fid, 4, '*uint8'))';
% calc.size=namevalue_Main_offset_size(2,1);
% icc.2 11.2.1 表86，第0~3个字节
null=fread_check(fid, 4, '*uint8');
calc.numN=fread_check(fid, 1, 'uint32');
table=cell(calc.numN,2);
none=cell(calc.numN,2);
for c=1:calc.numN
% for c=1:(namevalue_Main_offset_size(2,1)-12)/8
    fseek_check(fid, offset+namevalue_Main_offset_size(1,1)+4+8*c, 'bof');
    SUB=char(fread_check(fid, 4, '*uint8'))';
    table{c,1}=SUB;
    table{c,2}=fread_check(fid, 4, 'uint8')';
    str=SUB;
    old = ' ';
    new = '';
    SUB = replace(str,old,new);
    switch SUB
        case 'data'
%             table{c,2}=fread_check(fid, 1, 'float');
        case {'in','tget','tput','tsav','out'}
%             table{c,2}=fread_check(fid, 2, '*uint16');
%         case 'out'
        case 'env'
%             table{c,2}=fread_check(fid, 1, '*uint32');
        case {'curv','mtx','clut','calc','tint','elem'}
%             table{c,2}=fread_check(fid, 1, '*uint32');
        case {'copy','rotl','rotr','posd','flip','pop'}
%             table{c,2}=fread_check(fid, 2, '*uint16');
        case {'solv','tran'}
%             table{c,2}=fread_check(fid, 2, '*uint16');
        case {'sum','prod','min','max','and','or'}
%             table{c,2}=fread_check(fid, 1, '*uint16');
        case {'pi','-INF','+INF','NaN ',...
                'add','sub','mul','div','mod','pow',...
                'gama','sadd','ssub','smul','sdiv','sq',...
                'sqrt','cb','cbrt', 'abs', 'neg',...
                'rond','flor', 'ceil','trnc','exp',...
                'log','ln','sin','cos','tan',...
                'asin','acos','atan','atn2','ctop','ptoc',...
                'rnum','lt','le','eq','near','ge','gt',...
                'vmin','vmax','vand','vor'}
        case 'case'
        case 'if'     
        case 'sel'
        case 'else'
        case 'dflt'
        case 'fLab'
        case 'tLab'
        case 'not'
        case 'NaN'
        case 'tJab'
        case 'fJab'
        otherwise
            none{c,1}=SUB;
    end
end
% a=(namevalue_Main_offset_size(2,1)-12)-c*8;
% calc.part=char(fread_check(fid,a,'uint8')');
calc.table=table;
calc.none=none;
if calc.numE~=0
    calc.sub=read_calc_sub_element(fid,offset,namevalue_SUB_offset_size);
end
out=calc;

function out=read_calc_sub_element(fid,offset,namevalue_SUB_offset_size)
size_numE=size(namevalue_SUB_offset_size)/2;
sub=cell(size_numE(1,1),2);
for e=1:size_numE
    fseek_check(fid, offset+namevalue_SUB_offset_size(2*e-1,1), 'bof');
    f=char(fread_check(fid, 4, '*uint8'))';
    sub{e,1}=f;
    switch f
        case 'matf'
            sub{e,2}=read_matf_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1), 'bof');
        case 'cvst'
            sub{e,2}=read_cvst_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1), 'bof');
        case 'tint'
            sub{e,2}=read_tint_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1), 'bof',namevalue_SUB_offset_size(2*e,1));
        case 'clut'
            sub{e,2}=read_clut_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'JtoX'
            sub{e,2}=read_JtoX_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'XtoJ'
            sub{e,2}=read_JtoX_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'calc'
            sub{e,2}=read_calc_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'eclt'
            sub{e,2}=read_eclt_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'emtx'
            sub{e,2}=read_emtx_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'eobs'
            sub{e,2}=read_eobs_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'xclt'
            sub{e,2}=read_xclt_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'iemx'
            sub{e,2}=read_iemx_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'smet'
            sub{e,2}=read_smet_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'rclt'
            sub{e,2}=read_rclt_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        case 'robs'
            sub{e,2}=read_robs_element(fid, offset+namevalue_SUB_offset_size(2*e-1,1));
        otherwise
    end
end
out=sub;

function out=read_eclt_element(fid, offset)
fseek_check(fid, offset+8, 'bof');
eclt.numP=fread_check(fid, 1, 'uint16');
eclt.numQ=fread_check(fid, 1, 'uint16');
value = fread_check(fid, 3, '*uint16');
eclt.SpectralPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
eclt.SpectralPCSRange.End = uint16(floatSpRang2int(double(value(2))));
eclt.SpectralPCSRange.Step= value(3);
CLUTEncodingType=fread_check(fid, 1, 'uint16');
eclt.numG=fread_check(fid, 16, 'uint8');
numb_M=eclt.SpectralPCSRange.Step;
for i=1:eclt.numP
    numb_M=numb_M*eclt.numG(i,1);
end
switch CLUTEncodingType
    case 1
        %  float16
        value = fread_check(fid, numb_M, '*uint16');
        for i=1:numb_M
            value(i,1)=uint16(floatSpRang2int(double(value(i,1))));
        end
        Spectral_White=fread_check(fid, eclt.SpectralPCSRange.Step, '*uint16');
        for j=1
            Spectral_White(j,1)=uint16(floatSpRang2int(double(Spectral_White(j,1))));
        end
    case 2
        %  uint16
        value = fread_check(fid, numb_M, '*uint16');
        Spectral_White=fread_check(fid, eclt.SpectralPCSRange.Step, '*uint16');
    case 3
        %  uint8
        value = fread_check(fid, numb_M, '*uint8');
        Spectral_White=fread_check(fid, eclt.SpectralPCSRange.Step, '*uint8');
    case 0
        %  float32
        value = fread_check(fid, numb_M, 'float');
        Spectral_White=fread_check(fid, eclt.SpectralPCSRange.Step, 'float');
    otherwise
        value = 'null';
        Spectral_White='null';
end
eclt.CLUT=value;
eclt.Spectral_White=Spectral_White;
out=eclt;

function out=read_emtx_element(fid, offset)
fseek_check(fid, offset+8, 'bof');
emtx.numP=fread_check(fid, 1, 'uint16');
emtx.numQ=fread_check(fid, 1, 'uint16');
value = fread_check(fid, 3, '*uint16');
emtx.SpectralPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
emtx.SpectralPCSRange.End = uint16(floatSpRang2int(double(value(2))));
emtx.SpectralPCSRange.Step= value(3);
emtx.flag=fread_check(fid, 1, 'uint16');
emtx.white_Spectralemission=fread_check(fid, emtx.SpectralPCSRange.Step, 'float');
c=emtx.numQ*emtx.SpectralPCSRange.Step+emtx.SpectralPCSRange.Step;
emtx.Spectral_Matrix_emission=fread_check(fid, c, 'float');
out=emtx;

function out=read_eobs_element(fid, offset)
fseek_check(fid, offset+8, 'bof');
eobs.numP=fread_check(fid, 1, 'uint16');
eobs.numQ=fread_check(fid, 1, 'uint16');
value = fread_check(fid, 3, '*uint16');
eobs.SpectralPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
eobs.SpectralPCSRange.End = uint16(floatSpRang2int(double(value(2))));
eobs.SpectralPCSRange.Step= value(3);
eobs.flag=fread_check(fid, 1, 'uint16');
eobs.white_Spectralemission=fread_check(fid, eobs.SpectralPCSRange.Step, 'float');
out=eobs;

function out=read_xclt_element(fid, offset)
fseek_check(fid, offset+8, 'bof');
xclt.numP=fread_check(fid, 1, 'uint16');
xclt.numQ=fread_check(fid, 1, 'uint16');
CLUTEncodingType=fread_check(fid, 1, 'uint32');
xclt.numG=fread_check(fid, 16, 'uint8');
numb_M=xclt.numQ;
for i=1:xclt.numP
    numb_M=numb_M*xclt.numG(i,1);
end
switch CLUTEncodingType
    case 1
        %float 16
        value=fread_check(fid, numb_M, '*uint16');
        for i=1:numb_M
        value(i,1)=uint16(floatSpRang2int(double(value(i,1))));
        end
    case 2
        %uint16
        value=fread_check(fid, numb_M, '*uint16');
    case 3
        %uint8
        value=fread_check(fid, numb_M, '*uint8');
    case 0
        %float32
        value=fread_check(fid, numb_M, 'float');
    otherwise
        value='null';
end
xclt.CLUT=value;
out=xclt;

function out=read_iemx_element(fid, offset)
fseek_check(fid, offset+8, 'bof');
iemx.numP=fread_check(fid, 1, 'uint16');
iemx.numQ=fread_check(fid, 1, 'uint16');
value = fread_check(fid, 3, '*uint16');
iemx.SpectralPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
iemx.SpectralPCSRange.End = uint16(floatSpRang2int(double(value(2))));
iemx.SpectralPCSRange.Step= value(3);
fseek_check(fid, offset+namevalue_offset+20, 'bof');
iemx.white_Spectralemission=fread_check(fid, iemx.SpectralPCSRange.Step, 'float');
c=iemx.numQ*iemx.SpectralPCSRange.Step+iemx.SpectralPCSRange.Step;
iemx.Spectral_Matrix_emission=fread_check(fid, c, 'float');
out=iemx;

function out=read_smet_element(fid, offset)
fseek_check(fid, offset+8, 'bof');
smet.numP=fread_check(fid, 1, 'uint16');
smet.numQ=fread_check(fid, 1, 'uint16');
sparseMatrixEncodingType=fread_check(fid, 1, 'uint16');
fseek_check(fid, offset+namevalue_offset+16, 'bof');
smet.numG=fread_check(fid, 16, 'uint8');
numb_M=1;
for i=1:smet.numP
    numb_M=numb_M*smet.numG(i,1);
end
%稀疏矩阵编码
switch sparseMatrixEncodingType
    case 1
        %  sparseMatrixuint8
        sparse_Matrix=fread_check(fid, numb_M, 'uint8');
    case 2
        %  sparseMatrixuint16
        sparse_Matrix=fread_check(fid, numb_M, '*uint16');
    case 3
        %  sparseMatrixfloat16
        sparse_Matrix=fread_check(fid, numb_M, '*uint16');
        for j=1:numb_M
            sparse_Matrix(j,1)=uint16(floatSpRang2int(double(sparse_Matrix(j,1))));
        end
    case 4
        %  sparseMatrixfloat32
        sparse_Matrix=fread_check(fid, numb_M, 'float');
end
smet.sparse_Matrix=sparse_Matrix;
out=smet;

function out=read_rclt_element(fid, offset)
fseek_check(fid, offset+8, 'bof');
rclt.numP=fread_check(fid, 1, 'uint16');
rclt.numQ=fread_check(fid, 1, 'uint16');
rclt.flags=fread_check(fid, 2, 'uint16');
value = fread_check(fid, 3, '*uint16');
rclt.SpectralPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
rclt.SpectralPCSRange.End = uint16(floatSpRang2int(double(value(2))));
rclt.SpectralPCSRange.Step= value(3);
CLUTEncodingType=fread_check(fid, 1, 'uint16');
rclt.numG=fread_check(fid, 16, 'uint8');
numb_CLUT=clt.SpectralPCSRange.Step;
for i=1:rclt.numP
    numb_CLUT=numb_CLUT*rclt.numG(i,1);
end
switch CLUTEncodingType
    case 1
        %  float16
        sparse_Matrix=fread_check(fid, numb_CLUT, '*uint16');
        for j=1:numb_CLUT
            sparse_Matrix(j,1)=uint16(floatSpRang2int(double(sparse_Matrix(j,1))));
        end
    case 2
        %  uint16
        sparse_Matrix=fread_check(fid, numb_CLUT, '*uint16');
    case 3
        %  uint8
        sparse_Matrix=fread_check(fid, numb_CLUT, '*uint8');
    case 0
        %  float32
        sparse_Matrix=fread_check(fid, numb_CLUT, 'float');
end
rclt.CLUT=sparse_Matrix;
out=rclt;

function  out=read_robs_element(fid, offset)
fseek_check(fid, offset+namevalue_offset+8, 'bof');
robs.numP=fread_check(fid, 1, 'uint16');
robs.numQ=fread_check(fid, 1, 'uint16');
value = fread_check(fid, 3, '*uint16');
robs.SpectralPCSRange.Start = uint16(floatSpRang2int(double(value(1))));
robs.SpectralPCSRange.End = uint16(floatSpRang2int(double(value(2))));
robs.SpectralPCSRange.Step= value(3);
robs.flags=fread_check(fid, 1, 'uint16');
robs.Spectral_White=fread_check(fid, robs.SpectralPCSRange.Step, 'float');
out=robs;