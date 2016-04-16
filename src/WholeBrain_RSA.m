function WholeBrain_RSA(varargin)
  p = inputParser;
  p.KeepUnmatched = false;
  % ----------------------Set parameters-----------------------------------------------
  addParameter(p , 'debug'            , false     , @islogicallike );
  addParameter(p , 'RandomSeed'       , 0                          );
  addParameter(p , 'PermutationTest'  , false     , @islogicallike );
  addParameter(p , 'SmallFootprint'   , false     , @islogicallike );
  addParameter(p , 'Gtype'            , []        , @ischar        );
  addParameter(p , 'normalize'        , false                      );
  addParameter(p , 'bias'             , false     , @islogicallike );
  addParameter(p , 'simfile'          , []        , @ischar        );
  addParameter(p , 'sim_varname'      , []        , @ischar        );
  addParameter(p , 'filters'          , []                         );
  addParameter(p , 'data'             , []                         );
  addParameter(p , 'metadata'         , []        , @ischar        );
  addParameter(p , 'data_varname'     , []                         );
  addParameter(p , 'metadata_varname' , []        , @ischar        );
  addParameter(p , 'cvfile'           , []        , @ischar        );
  addParameter(p , 'cv_varname'       , []        , @ischar        );
  addParameter(p , 'cvscheme'         , []        , @isnumeric     );
  addParameter(p , 'cvholdout'        , []        , @isnumeric     );
  addParameter(p , 'finalholdout'     , 0         , @isintegerlike );
  addParameter(p , 'tau'              , 0.2       , @isnumeric     );
  addParameter(p , 'lambda'           , []        , @isnumeric     );
  addParameter(p , 'lambda1'          , []        , @isnumeric     );
  addParameter(p , 'LambdaSeq'        , []        , @ischar        );
  addParameter(p , 'AdlasOpts'        , struct()  , @isstruct      );
  addParameter(p , 'environment'      , 'condor'  , @ischar        );
  addParameter(p , 'SanityCheckData'  , []        , @ischar        );
  addParameter(p , 'SanityCheckModel' , []        , @ischar        );
  % Parameters below this line are unused in the analysis, may exist in the
  % parameter file because other progams use them.
  addParameter(p , 'COPY'             , []                         );
  addParameter(p , 'URLS'             , []                         );
  addParameter(p , 'executable'       , []                         );
  addParameter(p , 'wrapper'          , []                         );

  if nargin > 0
    parse(p, varargin{:});
  else
    jdat = loadjson('params.json');
    fields = fieldnames(jdat);
    jcell = [fields'; struct2cell(jdat)'];
    parse(p, jcell{:});
  end


  % private function.
  assertRequiredParameters(p.Results);

  DEBUG            = p.Results.debug;
  PermutationTest  = p.Results.PermutationTest;
  SmallFootprint   = p.Results.SmallFootprint;
  RandomSeed       = p.Results.RandomSeed;
  Gtype            = p.Results.Gtype;
  normalize        = p.Results.normalize;
  BIAS             = p.Results.bias;
  simfile          = p.Results.simfile;
  sim_varname      = p.Results.sim_varname;
  filter_labels    = p.Results.filters;
  datafile         = p.Results.data;
  data_varname     = p.Results.data_varname;
  cvfile           = p.Results.cvfile;
  cv_varname       = p.Results.cv_varname;
  cvscheme         = p.Results.cvscheme;
  cvholdout        = p.Results.cvholdout;
  finalholdoutInd  = p.Results.finalholdout;
  metafile         = p.Results.metadata;
  meta_varname     = p.Results.metadata_varname;
  tau              = p.Results.tau;
  lambda           = p.Results.lambda;
  lambda1          = p.Results.lambda1;
  LambdaSeq        = p.Results.LambdaSeq;
  opts             = p.Results.AdlasOpts;
  environment      = p.Results.environment;
  SanityCheckData  = p.Results.SanityCheckData;
  SanityCheckModel = p.Results.SanityCheckModel;

  rng(RandomSeed);

  % Check that the correct parameters are passed, given the desired algorithm
  [lambda, lambda1, LambdaSeq] = verifyLambdaSetup(Gtype, lambda, lambda1, LambdaSeq);

  % If values originated in a YAML file, and scientific notation is used, the
  % value may have been parsed as a string. Check and correct.
  if isfield(opts, 'tolInfeas')
    if ischar(opts.tolInfeas)
      opts.tolInfeas = sscanf(opts.tolInfeas, '%e');
    end
  end
  if isfield(opts, 'tolRelGap')
    if ischar(opts.tolRelGap)
      opts.tolRelGap = sscanf(opts.tolRelGap, '%e');
    end
  end

  if iscell(datafile)
    if length(datafile) == 1
      datafile = datafile{1};
    end
  end
  if iscell(metafile)
    if length(metafile) == 1
      metafile = metafile{1};
    end
  end

  % This is hack that made it a little easier to debug things locally.
  switch environment
  case 'condor'
    root = './';
    datadir = root;
    matfilename = 'results.mat';
    infofilename = 'info.mat';
  case 'chris'
    root = './';
    datadir = fullfile(root,'data');
    matfilename = 'results.mat';
    infofilename = 'info.mat';

  otherwise
    error('Environment %s not implemented.', environment);

  end
  % End hack

  % I use this "StagingContainer" idiom to have tight control over variable
  % names in the workspace.
  StagingContainer = load(fullfile(datadir,metafile), meta_varname);
  metadata = StagingContainer.(meta_varname);
  [~,fname,~] = fileparts(datafile);
  subjid = sscanf(fname, 's%d');
  if ~isempty(subjid)
    subject = find(subjid == [metadata.subject]);
  end
  metadata = metadata(subject);

  datapath = fullfile(datadir,datafile);
  fprintf('Loading data from  %s, subject number %d\n', datapath, subject);
  StagingContainer = load(datapath, data_varname);
  X = StagingContainer.(data_varname);
  fprintf('Initial dimensions: (%d,%d)\n', size(X,1), size(X,2));

  if isempty(filter_labels)
    rowfilter = true(1,size(X,1));
    colfilter = true(1,size(X,2));
  else
    if ~iscell(filter_labels);
      filter_labels = {filter_labels};
    end

    % metadata.filter points to a structured array of filters.
    % First, force filters to a common orientation.
    for i = 1:numel(metadata.filter)
      metadata.filter(i).filter = forceRowVec(metadata.filter(i).filter);
    end

    % Then select the filters
    z = false(1,numel(metadata.filter));
    for f = filter_labels;
      z(strcmp(f, {metadata.filter.label})) = true;
    end
    z = z & strcmp(data_varname, {metadata.filter.subset});

    filters.row = metadata.filter(z & [metadata.filter.dimension]==1);
    filters.col = metadata.filter(z & [metadata.filter.dimension]==2);
    rowfilter = all(cat(1, filters.row.filter),1);
    colfilter = all(cat(1, filters.col.filter),1);
    clear filters;
  end

  % I used to remove outliers within the code. Now, I do it ahead of time and
  % store the filters in metadata.filter.

%   allzero = any(X); % Identify columns with data
%   [~, reduxFilter] = removeOutliers(X);
%   % Note: reduxFilter field names are reversed...
%   filter = filter & reduxFilter.words';
%   vox = allzero & reduxFilter.voxels;
  X = X(rowfilter, colfilter);
  fprintf('Filtered dimensions: (%d,%d)\n', size(X,1), size(X,2));

  % Include voxel for bias
  fprintf('%-28s', 'Including Bias Unit:');
  msg = 'NO';
  if BIAS
    msg = 'YES';
    X = [X, ones(size(X,1),1)];
  end
  fprintf('[%3s]\n', msg);

  % Normalize columns of X
  fprintf('%-28s', 'Normalizing columns of X:');
  msg = 'NO';
  if normalize
    msg = 'YES';
  end
  fprintf('[%3s]\n', msg);

  cvpath = fullfile(datadir,cvfile);
  StagingContainer = load(cvpath, cv_varname);
  CV = StagingContainer.(cv_varname);
%   outlying_words = reduxFilter.words(filter);
  cvind = CV(rowfilter, cvscheme);
  finalholdout = cvind == finalholdoutInd;
  X(finalholdout,:) = [];
  cvind(finalholdout) = [];
  if finalholdoutInd > 0
    cvind(cvind>finalholdoutInd) = cvind(cvind>finalholdoutInd) - 1;
    % Adjust the cv holdout index(es) down if they are higher than the final holdout.
    if ~isempty(cvholdout)
      cvholdout(cvholdout>finalholdoutInd) = cvholdout(cvholdout>finalholdoutInd) - 1;
    end
  end

  %% ----------------Visual, Audio or Semantic similarities and processing----------------
  simpath = fullfile(datadir,simfile);
  StagingContainer = load(simpath, sim_varname);
  S = StagingContainer.(sim_varname);

  S = S(rowfilter,rowfilter); clear allSimStructs;
  S = S(~finalholdout, ~finalholdout);

  fprintf('Data loaded and processed.\n');

  %% ---------------------Setting algorithm parameters-------------------------
  switch Gtype
  case 'L1L2'
    [results,info] = learn_similarity_encoding(S, X, Gtype, ...
                      'tau'            , tau            , ...
                      'lambda1'        , lambda1        , ...
                      'cvind'          , cvind          , ...
                      'cvholdout'      , cvholdout      , ...
                      'normalize'      , normalize      , ...
                      'DEBUG'          , DEBUG          , ...
                      'PermutationTest', PermutationTest, ...
                      'SmallFootprint' , SmallFootprint , ...
                      'AdlasOpts'      , opts); %#ok<ASGLU>

  case 'grOWL'
    [results,info] = learn_similarity_encoding(S, X, Gtype, ...
                      'tau'            , tau            , ...
                      'lambda'         , lambda         , ...
                      'LambdaSeq'      , LambdaSeq      , ...
                      'cvind'          , cvind          , ...
                      'cvholdout'      , cvholdout      , ...
                      'normalize'      , normalize      , ...
                      'DEBUG'          , DEBUG          , ...
                      'PermutationTest', PermutationTest, ...
                      'SmallFootprint' , SmallFootprint , ...
                      'AdlasOpts'      , opts); %#ok<ASGLU>

  case 'grOWL2'
    [results,info] = learn_similarity_encoding(S, X, Gtype, ...
                      'tau'            , tau            , ...
                      'lambda'         , lambda         , ...
                      'lambda1'        , lambda1        , ...
                      'LambdaSeq'      , LambdaSeq      , ...
                      'cvind'          , cvind          , ...
                      'cvholdout'      , cvholdout      , ...
                      'normalize'      , normalize      , ...
                      'DEBUG'          , DEBUG          , ...
                      'PermutationTest', PermutationTest, ...
                      'SmallFootprint' , SmallFootprint , ...
                      'AdlasOpts'      , opts); %#ok<ASGLU>

  case 'searchlight'
    X = uncell(X);
    Y = uncell(Y)+1;
    cvind = uncell(cvind);
    colfilter = uncell(colfilter);

    % create a 3D binary mask
    z = strcmp({metadata.coords.orientation}, orientation);
    xyz = metadata.coords(z).xyz(colfilter,:);
    [mask,dxyz] = coordsTo3dMask(xyz);

    % Translate slradius (in mm) to sl voxels
    % N.B. Because voxels need not be symmetric cubes, but Seachmight will
    % generate symmetric spheres from a single radius parameter, we need to
    % select one value of the three that will be produced in this step. I am
    % arbitrarily choosing the max, to err on the side of being inclusive.
    slradius_ijk = max(round(slradius ./ dxyz));

    % create the "meta" neighbourhood structure
    meta = createMetaFromMask(mask, slradius_ijk);

    % Prepare parameters
    classifier = 'gnb_searchmight';
    if strcmp(slTestToUse,'accuracyOneSided_permutation')
      TestToUseCfg = {'testToUse',slTestToUse,slpermutations};
    else
      TestToUseCfg = {'testToUse',slTestToUse};
    end
    [am,pm,hm,fm] = computeInformationMap(X,Y,cvind,classifier,'searchlight', ...
                                meta.voxelsToNeighbours,meta.numberOfNeighbours,TestToUseCfg{:});

    results.accuracy_map = am;
    results.hitrate_map = hm;
    results.falsealarm_map = fm;
    results.pvalue_map = pm;
  end

  fprintf('Saving stuff.....\n');

  [results.subject] = deal(subjid);
  [results.finalholdout] = deal(finalholdoutInd);
  % Adjust the cvholdout indexes to accomodate the final holdout index.
  if isfield(results,'cvholdout')
    cvholdout = [results.cvholdout];
    z = cvholdout >= finalholdoutInd;
    cvholdout(z) = cvholdout(z) + 1;
    cvholdout = mat2cell(cvholdout(:),ones(numel(cvholdout),1));
    [results.cvholdout] = deal(cvholdout{:});
  end
  save(matfilename,'results');
  save(infofilename,'-struct','info');

  fprintf('Done!\n');
end

function [lam, lam1, lamSeq] = verifyLambdaSetup(Gtype, lambda, lambda1, LambdaSeq)
% Each algorithm requires different lambda configurations. This private
% function ensures that everything has been properly specified.
  switch Gtype
  case 'L1L2'
    if ~isempty(lambda)
      warning('Group Lasso does not use the lambda parameter. It is being ignored.');
    end
    assert(~isempty(lambda1)   , 'Group Lasso requires lambda1.');
    lam    = [];
    lam1   = lambda1;
    lamSeq = [];

  case 'grOWL'
    if ~isempty(lambda1)
      warning('grOWL does not use the lambda1 parameter. It is being ignored.');
    end
    assert(~isempty(lambda)    , 'Group Lasso requires lambda.');
    assert(~isempty(LambdaSeq) , 'A LambdaSeq type (linear or exponential) must be set when using grOWL*.');
    lam    = lambda;
    lam1   = [];
    lamSeq = LambdaSeq;

  case 'grOWL2'
    assert(~isempty(lambda)    , 'grOWL2 Lasso requires lambda.');
    assert(~isempty(lambda1)   , 'grOWL2 requires lambda1.');
    assert(~isempty(LambdaSeq) , 'A LambdaSeq type (linear or exponential) must be set when using grOWL*.');
    lam    = lambda;
    lam1   = lambda1;
    lamSeq = LambdaSeq;
  end
end

function assertRequiredParameters(params)
  required = {'Gtype'    , 'simfile' , 'sim_varname'   , 'data', ...
              'metadata' , 'cvfile'  , 'cvscheme'  ,'cvholdout' , 'finalholdout'};
  N = length(required);
  for i = 1:N
    req = required{i};
    assert(isfield(params,req), '%s must exist in params structure! Exiting.',req);
    assert(~isempty(params.(req)), '%s must be set. Exiting.',req);
  end
end

function b = islogicallike(x)
  b = any(x == [1,0]);
end

function b = isintegerlike(x)
  b = mod(x,1) == 0;
end

function r = forceRowVec(v)
  r = v(1:end);
end

function c = forceColVec(v)
  c = v(:);
end
