%% DRM transmitter

% disable clear for unit_tests and receiver
% clear all
% clc

%% calculate global variables, for the list of assumptions see drm_global_variables.m
run drm_global_variables

%% open binary file (aac encoded) for transmission
fid = fopen('sample_short.aac');
if fid == -1
    error('file not found')
end   

%% create (dummy) bit streams
%msc_stream = randint(MSC.M_TF, MSC.L_MUX); % one MSC multiplex frame
%sdc_stream = randint(1, SDC.L_SDC); % one SDC block
fac_stream = drm_generate_fac(FAC); % first, intermediate and last FAC block
sdc_stream = drm_generate_sdc(SDC); % SDC block to be sent with every super transmission frame
%fac_stream = randint(1, FAC.L_FAC); % one FAC block

%% preallocate memory for output, calculate number of frames
msc_data = fread(fid, [1, inf], 'ubit1');
frewind(fid); % set file pointer back to beginning of file
n_stf = ceil(length(msc_data)/(MSC.M_TF*MSC.L_MUX)); % number of super transmission frames
% complex baseband output preallocation
complex_baseband = zeros(n_stf, OFDM.M_TF*OFDM.N_S*(OFDM.nfft + OFDM.nguard));

%% interate as long there is data in the aac file, then stop
for n = 1 : n_stf
    %% read data for MSC.M_TF multiplex frames
    msc_stream = fread(fid, [1, MSC.M_TF*MSC.L_MUX], 'ubit1');
    % zeropadding if end of file is reached
    if length(msc_stream) ~= MSC.M_TF*MSC.L_MUX
        msc_stream = [msc_stream, zeros(1, MSC.M_TF*MSC.L_MUX - length(msc_stream))];
    end
    msc_stream = transpose(reshape(msc_stream, MSC.L_MUX, MSC.M_TF));
    
    %% energy dispersal
    msc_stream_scrambled = cell(MSC.M_TF, 1);
    fac_stream_scrambled = zeros(3, FAC.L_FAC);
    for i = 1 : MSC.M_TF
        msc_stream_scrambled{i} = drm_scrambler(msc_stream(i, :));
        fac_stream_scrambled(i,:) = drm_scrambler(fac_stream(i,:));
    end
    sdc_stream_scrambled = drm_scrambler(sdc_stream);
    

    %% partitioning
    msc_stream_partitioned = cell(MSC.M_TF, 1);
    fac_stream_partitioned = zeros(3, FAC.L_FAC);
    for i = 1 : MSC.M_TF
        msc_stream_partitioned{i} = drm_mlc_partitioning(msc_stream_scrambled{i}, 'MSC', MSC);
        fac_stream_partitioned(i,:) = drm_mlc_partitioning(fac_stream_scrambled(i,:), 'FAC', FAC);
    end
    sdc_stream_partitioned = drm_mlc_partitioning(sdc_stream_scrambled, 'SDC', SDC);

    %% encoding
    msc_stream_encoded = cell(MSC.M_TF, 1);
    fac_stream_encoded = zeros(3, 2*FAC.N_FAC);
    for i = 1 : MSC.M_TF
        msc_stream_encoded{i} = drm_mlc_encoder(msc_stream_partitioned{i}, 'MSC', MSC);
        fac_stream_encoded(i,:) = drm_mlc_encoder(fac_stream_partitioned(i,:), 'FAC', FAC);
    end
    sdc_stream_encoded = drm_mlc_encoder(sdc_stream_partitioned, 'SDC', SDC);

    %% interleaving
    msc_stream_interleaved = cell(MSC.M_TF, 1);
    fac_stream_interleaved = zeros(3, 2*FAC.N_FAC);
    for i = 1 : MSC.M_TF
        msc_stream_interleaved{i} = drm_mlc_interleaver(msc_stream_encoded{i}, 'MSC', MSC);
        fac_stream_interleaved(i,:) = drm_mlc_interleaver(fac_stream_encoded(i,:), 'FAC', FAC);
    end
    sdc_stream_interleaved = drm_mlc_interleaver(sdc_stream_encoded, 'SDC', SDC);

    %% bit to symbol mapping
    msc_stream_mapped = zeros(MSC.M_TF, MSC.N_MUX);
    fac_stream_mapped = zeros(3, FAC.N_FAC);
    for i = 1 : MSC.M_TF
        msc_stream_mapped(i,:) = drm_mapping(msc_stream_interleaved{i}, 'MSC', MSC);
        fac_stream_mapped(i,:) = drm_mapping(fac_stream_interleaved(i,:), 'FAC', FAC);
    end
    sdc_stream_mapped = drm_mapping(sdc_stream_interleaved, 'SDC', SDC);

    %% MSC cell interleaving
    msc_stream_map_interl = zeros(MSC.M_TF, MSC.N_MUX);
    for i = 1 : MSC.M_TF
        msc_stream_map_interl(i,:) = drm_mlc_interleaver(msc_stream_mapped(i,:), 'MSC_cells', MSC);
    end

    %% build super transmission frame
    super_tframe = drm_cell_mapping(msc_stream_map_interl, sdc_stream_mapped, fac_stream_mapped, MSC, OFDM);

    %% OFDM (complex baseband output)
    complex_baseband_new = drm_ofdm(super_tframe, OFDM);
    complex_baseband(n, :) = complex_baseband_new;
    
end

%% write to wav file
% reshape baseband signal to one vector so that it is treated as mono
baseband_mono = zeros(n_stf* OFDM.M_TF*OFDM.N_S*(OFDM.nfft + OFDM.nguard), 1);
for i = 1:n_stf
    baseband_mono((i-1)* OFDM.M_TF*OFDM.N_S*(OFDM.nfft + OFDM.nguard) + 1 : i * OFDM.M_TF*OFDM.N_S*(OFDM.nfft + OFDM.nguard)) = complex_baseband(i, :);
end
fs = 48000; % wav file sampling rate in Hz
N = 16;
t = 0:1/fs:n_stf*1.2 - 1/fs;
rf = 5 .* exp(2i*pi*12000*t);
baseband_mono_rf = real(rf .* transpose(baseband_mono));
%baseband_mono_rf = [baseband_mono_rf, baseband_mono_rf, baseband_mono_rf, baseband_mono_rf];
filename = 'transmitter_out.wav';
wavwrite(baseband_mono_rf, fs, N, filename);

%% clear data
clear msc_stream sdc_stream fac_stream
clear msc_stream_scrambled sdc_stream_scrambled fac_stream_scrambled
clear msc_stream_partitioned sdc_stream_partitioned fac_stream_partitioned
%clear msc_stream_encoded sdc_stream_encoded fac_stream_encoded
%clear msc_stream_interleaved sdc_stream_interleaved fac_stream_interleaved
%clear msc_stream_mapped
%clear msc_stream_map_interl sdc_stream_mapped fac_stream_mapped