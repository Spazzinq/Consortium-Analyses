function summarized_MCPA_struct = summarize_MCPA_Struct(summary_function,MCPA_struct, summarize_dimensions)
%SUMMARIZE_MCPA_STRUCT Convert an MCPA struct of windowed data to
%multivariate patterns using any summarizing function, such as nanmean.


%% Convert the inputs to correct format
% Convert summary function into a function handle

if ischar(summary_function)
    summary_function = {str2func(summary_function)};
elseif isa(summary_function,'function_handle')
    summary_function = {summary_function};
elseif isempty(summary_function)
    warning('No summarizing function specified. Reshaping dimensions only.')
end

% Convert summarize_dimensions into cell array
if ischar(summarize_dimensions)
    warning('Please provided cell array of dimensions to summarize. Automatically converting...')
    summarize_dimensions = {summarize_dimensions};
elseif isnumeric(summarize_dimensions)
    warning('Please provided cell array of dimensions to summarize. Looking up dimension names in MCPA''s dimensions field...')
    if ~isfield(MCPA_struct,'dimensions')
        warning('No ''dimension'' field found in MCPA struct, so no dimension labels available. Assigning numeric labels.')
        MCPA_struct.dimensions = cellfun(@(x) strcat('PatternDim',x), cellfun(@num2str, num2cell(1:ndims(MCPA_struct.patterns)),'UniformOutput',false),'UniformOutput',false);
    end
    summarize_dimensions = MCPA_struct.dimensions(summarize_dimensions);
    dim_str = join(summarize_dimensions,', ');
    fprintf('Converted numeric dimension indices to: %s', dim_str{:})
end

%% Create copies of dimensions and of pattern matrix
dimension_labels = MCPA_struct.dimensions;
pattern_matrix = MCPA_struct.patterns;

%% Get summarized
% Step through the dimensions listed from left to right. If a dimension
% contains the concatenation operator (X), then reshape the pattern matrix
% and rename the dimension(s). Otherwise, perform the summarizing function
% on the dimension.

% create a list of the operations happening on our data for later use in our summarizing loop
% this will be a list of either 'Nan' or @function_handle. 'Nan' is only used when we're concatenating to preserve array dimensions
summary_operations = cell(size(summarize_dimensions));

% summary function will be a list of operators, it will not be equal to summarize_dimensions if the user entered a concatenation
if length(summary_function) ~= length(summarize_dimensions)
    % if we're concatenating instead of summarizing, we need to figure out what index in the order of operations to put a 'Nan'
    dim_to_pad = find(~isempty(strfind(summarize_dimensions, 'X')));

    summ_function_idx = 1;
    for i = 1:length(summarize_dimensions) % here we're filling in summary_operations
        if i == dim_to_pad
            summary_operations{i} = 'Nan';
        else
            summary_operations{i} = summary_function{summ_function_idx};
            
            if length(summary_function) > 1
                summ_function_idx = summ_function_idx+1;
            end
        end
    end
else
    summary_operations = summary_function;
end
            
%% new approach
dims_summarized = [];

for curr_dim = 1:length(summarize_dimensions)
    
    operation = summary_operations(curr_dim);
    
    % Perform concatenations
    concat = strsplit(summarize_dimensions{curr_dim}, 'X');
    if length(concat) == 2
        try
            first_dim_to_concat = find(strcmp(dimension_labels,concat{1}));
            second_dim_to_concat = find(strcmp(dimension_labels,concat{2}));
            pattern_matrix = concatenate_dimensions(pattern_matrix, [first_dim_to_concat,second_dim_to_concat]);
            
            % get the new dimensions
            dimension_labels{first_dim_to_concat} = [dimension_labels{first_dim_to_concat}, '+', dimension_labels{second_dim_to_concat}];
            dimension_labels{second_dim_to_concat} = [];
            
        catch concat_error
            warning(concat_error.message)
            error('Failed to concatenate dimensions: %s', summarize_dimensions{curr_dim})
        end
    elseif ~isempty(operation) 
        try
            dim_to_summarize = find(strcmp(dimension_labels, summarize_dimensions{curr_dim}));
            
            dims_summarized = [dims_summarized dim_to_summarize];
            
            % create temp pattern matrix to store new data
            inds = size(pattern_matrix);
            inds(dim_to_summarize) = length(operation{:});
            temp_pattern_matrix = nan(inds);
            
            if length(operation{:}) > 1 % if we have 2 operations, that index in the cell array will be {1x2}, so we need this to get it to {@min, @max}
                operation = operation{:}; 
            end
            
            for summerizer = 1:length(operation) % apply each summarizing function to the specified dimension
                inds = repmat({':'},1,ndims(temp_pattern_matrix));
                inds{dim_to_summarize} = summerizer;
                
                % if we applied 1 function, that dimension will now be size 1, if we applied 2 functions, it will be size 2
                % for example, if we applied nanmean to time, we get 1 x 8 x139 x 15 x 4 x16 but if we applied min and max to time we get 2 x 8 x 138 x 15 x 4 x 16
                temp_pattern_matrix(inds{:}) = operation{summerizer}(pattern_matrix,dim_to_summarize);  
            end
            
            pattern_matrix = temp_pattern_matrix;

            % Then keep track of remaining dimensions in list
            dimension_labels{dim_to_summarize} = [];

        catch averaging_error
            warning(averaging_error.message);
            error('Failed to successfully summarize dimension: %s', summarize_dimensions{curr_dim});
        end
    end
end

if ~isempty(strcmp('session', dimension_labels))
    session_idx = find(strcmp('session', dimension_labels));
    s = size(pattern_matrix);
    if s(session_idx) == 1 % we don't want to loose this dimension if it is 1
        to_remove = s ~= 1;
        to_remove(session_idx) = 1;
        summarized_MCPA_struct_pattern = reshape(pattern_matrix,s(to_remove));
    else
        concat_to = find(strcmp(dimension_labels, 'feature'));
        summarized_MCPA_struct_pattern = concatenate_dimensions(pattern_matrix, [concat_to,dims_summarized]);
    end
end    

dimension_labels = dimension_labels(~cellfun('isempty',dimension_labels));

%% Return the new struct
try
    summarized_MCPA_struct = MCPA_struct;
    summarized_MCPA_struct.created = datestr(now);
    summarized_MCPA_struct.summarizing_function = summary_function;
    summarized_MCPA_struct.patterns = summarized_MCPA_struct_pattern;
    summarized_MCPA_struct.dimensions = dimension_labels;
    summarized_MCPA_struct.summarize_dimensions = summarize_dimensions;
    fprintf(' Done.\n');
    
catch
    error('Failed to create the new struct');
end



end
