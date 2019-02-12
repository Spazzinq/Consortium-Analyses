function allsubj_results = nfold_classify_ParticipantLevel(MCP_struct,varargin)
%% nfold_classify_ParticipantLevel takes an MCP struct and performs
% n-fold cross-validation for n subjects to classify individual
% participants' average response patterns. This wrapper assumes that
% features will be averaged within-participants to produce a single
% participant-level observation. Thus the training set is constrained to
% the number of participants minus 1. Several parameters can be changed,
% including which functions are used to generate features and what
% classifier is trained. See Arguments below:
%
% Arguments:
% incl_channels: channels to include in the analysis. Default: all channels
% incl_subjects: index of participants to include. Default: all participants
% time_window: [onset, offset] in seconds. Default [2,6]
% conditions: cell array of condition names / trigger #s. Default: {1,2}
% summary_handle: function handle (or char of function name) to specify how
% time-x-channel data should be summarized into features. Default: nanmean
% setsize: number of channels to analyze (for subset analyses) Default: all
% test_handle: function handle for classifier. Default: mcpa_classify
% opts_struct: contains additional classifier options. Default: empty struct

%% Load MCP struct if necessary
if isstring(MCP_struct)
    MCP_struct = load(MCP_struct,'-mat');
    varname = fieldnames(MCP_struct);
    MCP_struct = eval(['MCP_struct.' varname{1}]);
end

%% Parse out the input data
p = inputParser;
addParameter(p,'incl_channels',[1:max(arrayfun(@(x) size(x.fNIRS_Data.Hb_data.Oxy,2),MCP_struct))],@isnumeric);
addParameter(p,'incl_subjects',[1:length(MCP_struct)],@isnumeric);
addParameter(p,'time_window',[2,6],@isnumeric);
addParameter(p,'conditions',{1,2},@iscell);
addParameter(p,'summary_handle',@nanmean);
addParameter(p,'setsize',max(arrayfun(@(x) size(x.fNIRS_Data.Hb_data.Oxy,2),MCP_struct)),@isnumeric);
addParameter(p,'test_handle',@mcpa_classify);
addParameter(p,'opts_struct',struct,@isstruct);
parse(p,varargin{:})

%% Setting up the combinations of channel subsets
% Create all possible subsets. If setsize is equal to the total number of
% channels, there will only be one 'subset' which is the full channel
% array. If setsize is less than the total number of channels, there will
% be n-choose-k subsets to analyze.
sets = nchoosek(p.Results.incl_channels,p.Results.setsize);

%% Build MCPA struct for all subjects in the MCP
% Step 1: Epoching the data by time window and averaging the epochs
% together at the subject level
mcpa_struct = MCP_to_MCPA(MCP_struct,p.Results.incl_subjects,p.Results.incl_channels,p.Results.time_window);

% Step 2: Apply the desired function (e.g., @nanmean) for summarizing time
% window data. You can write custom functions to deal with time- and
% channel-domain data however you want. Default behavior is to apply the
% function along the first dimension of the MCPA pattern, but this can also
% be changed.
mcpa_summ = summarize_MCPA_Struct(p.Results.summary_handle,mcpa_struct);

%% Set up the results structure which includes a copy of MCPA_pattern
allsubj_results = [];
allsubj_results.MCPA_patterns = mcpa_struct.patterns;
allsubj_results.MCP_data = MCP_struct;
allsubj_results.created = datestr(now);
allsubj_results.test_handle = p.Results.test_handle;
allsubj_results.test_type = 'N-fold (Leave one subject out), Classify participant level';
allsubj_results.setsize = p.Results.setsize;
allsubj_results.func_handle = p.Results.summary_handle;
allsubj_results.incl_channels = mcpa_struct.incl_channels;
allsubj_results.conditions = p.Results.conditions;
allsubj_results.subsets = sets;

n_subj = length(MCP_struct);
n_sets = size(sets,1);
n_chan = length(p.Results.incl_channels);
% n_events = max(arrayfun(@(x) max(sum(x.fNIRS_Data.Onsets_Matrix)),MCP_struct));
n_cond = length(p.Results.conditions);

for cond_id = 1:n_cond
    allsubj_results.accuracy(cond_id).condition = allsubj_results.conditions(cond_id);
    allsubj_results.accuracy(cond_id).subjXchan = nan(n_subj,n_chan);
    allsubj_results.accuracy(cond_id).subsetXsubj = nan(n_sets,n_subj);
end

for s_idx = 1:length(mcpa_summ.incl_subjects)
    fprintf('Running %g feature subsets for Subject %g / %g',n_sets,s_idx,n_subj);
    
    %% Extract training and testing data
    group_subvec = 1:length(mcpa_summ.incl_subjects);
    group_subvec(s_idx) = [];
    
    % Set logical flags for indexing the conditions that will be compared.
    % Loop through the whole list of conditions and create flags for each.
    cond_flags = cell(n_cond,1);
    group_data = [];
    group_labels = [];
    subj_data = [];
    subj_labels = [];
    for cond_idx = 1:n_cond
        if ischar(p.Results.conditions{cond_idx}) || isstring(p.Results.conditions{cond_idx}) || iscellstr(p.Results.conditions{cond_idx})
            cond_flags{cond_idx} = strcmp(p.Results.conditions{cond_idx},mcpa_summ.event_types);
        else
            cond_flags{cond_idx} = p.Results.conditions{cond_idx};
        end
        
        % Extract training data
        % group_data_tmp averages across all matching triggers for a
        % condition and outputs a subj-x-chan matrix
        group_data_tmp = squeeze(mean(mcpa_summ.patterns(cond_flags{cond_idx},p.Results.incl_channels,group_subvec),1))';
        group_labels_tmp = repmat(cellstr(string(p.Results.conditions{cond_idx})),size(group_data_tmp,1),1);
        group_data = [ group_data; group_data_tmp ];
        group_labels = [ group_labels; group_labels_tmp ];
        
        % Extract test data
        subj_data_tmp = mcpa_summ.patterns(cond_flags{cond_idx},p.Results.incl_channels,s_idx);
        subj_labels_tmp = repmat(cellstr(string(p.Results.conditions{cond_idx})),size(subj_data_tmp,1),1);
        subj_data = [ subj_data; subj_data_tmp ];
        subj_labels = [ subj_labels; subj_labels_tmp ];
    end
    
    %% Run over channel subsets
    temp_set_results_cond = nan(n_cond,n_sets,n_chan);
    
    for set_idx = 1:n_sets
        tic;
        % Report at every 5% progress
        status_jump = floor(n_sets/20);
        if ~mod(set_idx,status_jump)
            fprintf(' .')
        end
        % Select the channels for this subset
        set_chans = sets(set_idx,:);
        
        if n_cond==2
            % Run classifier
            temp_test_labels = p.Results.test_handle(...
                group_data(:,set_chans), ...
                group_labels,...
                subj_data(:,set_chans)...
                );
            
            % Compare the labels output by the classifier to the known labels
            temp_acc1 = cellfun(@strcmp,...
                subj_labels(strcmp('cond1',subj_labels)),... % known labels
                temp_test_labels(strcmp('cond1',subj_labels))...% classifier labels
                );
            temp_acc2 = cellfun(@strcmp,...
                subj_labels(strcmp('cond2',subj_labels)),... % known labels
                temp_test_labels(strcmp('cond2',subj_labels))... % classifier labels
                );
            
            % Temporary results from each set are stored in a n_sets x n_chan
            % matrix, so that averaging can be done both across sets (to
            % determine channel mean performance) and across channels (to
            % determine set mean performance)
            temp_set_results_cond(1,set_idx,set_chans) = nanmean(temp_acc1);
            temp_set_results_cond(2,set_idx,set_chans) = nanmean(temp_acc2);
            
        else
            % Write the multiclass version here
            allsubj_results = pairwise_rsa_leaveoneout(mcpa_summ.patterns);
        end
        
        % After running at the subsets, write out the results to the arrays
        for cond_idx = 1:n_cond
            allsubj_results.accuracy(cond_idx).subsetXsubj(:,s_idx) = nanmean(temp_set_results_cond(cond_idx,:,:),3);
            allsubj_results.accuracy(cond_idx).subjXchan(s_idx,:) = nanmean(temp_set_results_cond(cond_idx,:,:),2);
        end
        
        fprintf(' %0.1f mins\n',toc/60);
        
    end
    
end

%% Visualization
if n_sets > 1 && length(p.Results.conditions)==2
    
    figure
    errorbar(1:size(allsubj_results.accuracy.cond1.subjXchan,2),mean(allsubj_results.accuracy.cond1.subjXchan),std(allsubj_results.accuracy.cond1.subjXchan)/sqrt(size(allsubj_results.accuracy.cond1.subjXchan,1)),'r')
    hold;
    errorbar(1:size(allsubj_results.accuracy.cond2.subjXchan,2),mean(allsubj_results.accuracy.cond2.subjXchan),std(allsubj_results.accuracy.cond2.subjXchan)/sqrt(size(allsubj_results.accuracy.cond2.subjXchan,1)),'k')
    title('Decoding Accuracy across all channels: Red = Cond1, Black = Cond2')
    set(gca,'XTick',[1:length(p.Results.incl_channels)])
    set(gca,'XTickLabel',p.Results.incl_channels)
    hold off;
    
    figure
    errorbar(1:size(allsubj_results.accuracy.cond1.subjXchan,1),mean(allsubj_results.accuracy.cond1.subjXchan'),repmat(std(mean(allsubj_results.accuracy.cond1.subjXchan'))/sqrt(size(allsubj_results.accuracy.cond1.subjXchan,2)),1,size(allsubj_results.accuracy.cond1.subjXchan,1)),'r')
    hold;
    errorbar(1:size(allsubj_results.accuracy.cond2.subjXchan,1),mean(allsubj_results.accuracy.cond2.subjXchan'),repmat(std(mean(allsubj_results.accuracy.cond2.subjXchan'))/sqrt(size(allsubj_results.accuracy.cond2.subjXchan,2)),1,size(allsubj_results.accuracy.cond2.subjXchan,1)),'k')
    title('Decoding Accuracy across all subjects: Red = Cond1, Black = Cond2')
    set(gca,'XTick',[1:p.Results.incl_subjects])
    hold off;
    
end

end