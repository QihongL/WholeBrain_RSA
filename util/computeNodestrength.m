function results = computNodestrength(results, varargin)
  p = inputParser();
  addRequired(p,'results', @isstruct);
  addParameter(p,'scale', true, @islogical);
  parse(p, results, varargin{:});

  results = p.Results.results;
  ScaleMax1 = p.Results.scale;

  ss = [results.subject];
  subject = unique(ss);
  N = numel(subject);
  NS(N) = init_results('Template','default');
  permfields = fieldnames(NS);
  fprintf('*** Aggregating Permutation Results ***\n')
  for i = 1:N
    s = subject(i);
    fprintf('Subject %3d: ', s);
    idx = find(ss==s);
    BiasUnit = results(idx(1)).bias;

    % Count nz rows in Uz
    nzr = [results(idx).nz_rows];
    if BiasUnit
      nnzr = sum(nzr(1:(end-1),:),2);
    else
      nnzr = sum(nzr(1:end,:),2);
    end

    % Compute and aggregate node strengths
    nodestrength = zeros(numel(idx), numel(nnzr));
    nzv = zeros(numel(idx),1);
    nchar = 0;
    for ii = 1:numel(idx);
      if nchar > 0
        fprintf(repmat('\b',1,nchar));
      end
      nchar = fprintf('%6d', ii);
      j = idx(ii);
      if BiasUnit
        Uz = results(j).Uz(1:(end-1),:);
        z = results(j).nz_rows(1:(end-1),:);
      else
        Uz = results(j).Uz;
        z = results(j).nz_rows;
      end
      Uz = Uz(z,:);
      nzv(ii) = nnz(z);
      nodestrength(ii, z) = sum(abs(Uz * Uz'));
    end
    fprintf('\n');

    if ScaleMax1
      nodestrength = bsxfun(@rdivide, nodestrength, max(nodestrength,[],2));
    end

    mean_nodestrength = mean(nodestrength);
    mean_nzv = mean(nzv);

    for ii = 1:numel(permfields);
      f = permfields{ii};
      if isfield(results, f)
        NS(i).(f) = results(idx(1)).(f);
      end
    end
    NS(i).count_nz_rows = nnzr;
    if BiasUnit
      NS(i).nz_rows = [nnzr>0;true];
    else
      NS(i).nz_rows = nnzr>0;
    end
    NS(i).nodestrength = nodestrength;
    NS(i).mean_nodestrength = mean_nodestrength;
    NS(i).nzv = nzv;
    NS(i).mean_nzv = mean_nzv;
  end
end
