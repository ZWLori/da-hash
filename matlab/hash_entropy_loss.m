function[Y] = hash_entropy_loss(X, labels, actLabels, lopts, dzdy)
% HASH_ENTROPY_LOSS This is the hash loss and the unsupervised entropy loss
%for da_hash
%   Y = HASH_ENTROPYLOSS(X, LABELS, LOPTS) applies the hash loss and the
%   unsupervised entropy loss to the data X.
%   X has dimension H x W x hashSize x N,
%   packing N arrays of W x H hashSize-dimensional vectors.
%
%   LABELS contains the class labels, which should be integers in the range
%   0 to C. 0 indicates it is a target data point. 
%   LABELS is an array with N elements.
%   LOPTS has the following fields
%     - `lopts.K` the K parameter for the da_hash
%     - `lopts.C` the labels in the dataset (1,2,...,C)
%     - `lopts.l1` Weight for hash loss
%     - `lopts.entpW` Weight for entropy loss
%     - `lopts.beta` Weight for Euclidean loss
%     - `lopts.supHashW` Weight for supervised positive samples
%
%   DZDX = HASH_ENTROPYLOSS(X, LABELS, LOPTS, DZDY) computes the 
%   derivative of the block projected onto DZDY. DZDX and DZDY have the 
%   same dimensions as X and Y respectively.

% Copyright (C) 2016-17 Hemanth Venkateswara.
% All rights reserved.

checkLabels = reshape(repmat(lopts.C, lopts.K, 1), 1, []);
if length(labels) > length(checkLabels) && isequal(labels(1:length(checkLabels)), checkLabels)
    jeLoss = false;
else
    jeLoss = false;
end

U = squeeze(X); % convert to D x N array
srcIds = labels > 0;
tgtIds = labels == 0;
ns = sum(srcIds);
nt = sum(tgtIds);
Us = U(:,srcIds);
Ut = U(:,tgtIds);
B = single(sign(U));
B(B==0) = 1;

% Since there are few similar matches, we increase the weight for a similar match
if isfield(lopts, 'supHashW')
    weight = lopts.supHashW;
else
    weight = 100;
end
l1 = lopts.l1; % Weight for hash Similarity loss
entpW = lopts.entpW; % Weight for Entropy loss
beta = lopts.beta; % Weight for bin Euclidean loss

ls = labels(srcIds);
lt = actLabels(tgtIds);     %zwl add tgt labels in learning
if size(ls,1) == 1
    ls = ls';
end
if size(lt, 1) == 1
    lt = lt';
end
Usdot = Us'*Us;
Utdot = Ut'*Ut;
expUsdot = exp(-0.5*Usdot);
expUsdot(isinf(expUsdot)) = 1e30;
expUtdot = exp(-0.5*Utdot);
expUtdot(isinf(expUtdot)) = 1e30;
% As = 1./(1 + exp(-0.5*Usdot)); % 0.5*<ui uj>
As = 1./(1 + expUsdot); % 0.5*<ui uj>
if any(isnan(As(:)))
    error('As is nan');
end
As(1:ns+1:end) = 1; % Set diagonal = 1, since all same pairs
At = 1./(1 + expUtdot);
if any(isnan(At(:)))
    error('At is nan');
end
At(1:nt+1:end) = 1;

if ns == 1
    S = 1;
else
    S = squareform(pdist(ls)); % Similarity matrix
end
S(S>0) = -1;
S(S==0) = 1;
S(S==-1) = 0;
S = single(S);
W = ones(ns); % [ns x ns] matrix
W(logical(S)) = weight;
W = single(W);

if nt == 1
    St = 1;
else
    St = squareform(pdist(lt));
end
St(St>0) = -1;
St(St==0) = 1;
St(St==-1) = 0;
St = single(St);
Wt = ones(nt); % [nt x nt] matrix
Wt(logical(St)) = weight;
Wt = single(Wt);

Ustdot = Us'*Ut;
expUstdot = exp(-0.5*Ustdot);
expUstdot(isinf(expUstdot)) = 1e30;
% Ast = 1./(1 + exp(-0.5*Ustdot)); % 0.5*<ui uj> % [ns x nt]
Ast = 1./(1 + expUstdot); % 0.5*<ui uj> % [ns x nt]
if any(isnan(Ast(:)))
    error('Ast is nan');
end

if nargin <=4 || isempty(dzdy)
    Y = 0;
    % Hamming Loss between Source and Source
    expUsdot = exp(0.5*Usdot);
    expUsdot(isinf(expUsdot)) = 1e30;
    expUtdot = exp(0.5*Utdot);
    expUtdot(isinf(expUtdot)) = 1e30;
    Ls = (l1).*W.*(log(1 + expUsdot) - S.*(0.5*Usdot));
    Lt = (l1).*Wt.*(log(1+expUtdot) - St.*(0.5*Utdot));   % zwl Hamming loss btw tgt and tgt
    Y = Y + sum(Ls(:)) + sum(Lt(:));
    if any(isnan(Ls(:)))
        error('Ls is nan');
    end
    if any(isnan(Lt(:)))
        error('Lt is nan');
    end
    % Joint Entropy Loss
    Lst = 0;
    if jeLoss
        % Entropy Loss between Source and Target
        Lst = entpW.*jointEntropyCostAndGradComplex(U, labels, lopts.K, 1);
        Y = Y + sum(Lst(:));
    end
    % Binary Loss
    Lb = beta*trace((B-U)'*(B-U));
    Y = Y + sum(Lb(:));
    fprintf('Ls = %0.3f, Lt = %0.3f, Lst = %0.3f, Lb = %0.3f, ', sum(Ls(:)), sum(Lt(:)), sum(Lst(:)), Lb);
else
    % All gradients
    gpuMode = isa(U, 'gpuArray') ;
    if gpuMode
        gradst = gpuArray(zeros(size(Us,1), (ns + nt)));
    else
        gradst = zeros(size(Us,1), (ns + nt));
    end
    
    % Hamming Gradient between Source and Source
    gradSS = W.*(0.5*(As-S)); % These () are very important
    gradSS = (l1).*Us*(gradSS + gradSS');
    gradst(:, srcIds) = gradst(:, srcIds) + gradSS;
    
    % Entropy gradient between Source and Target
    if jeLoss
        gradJE = entpW.*jointEntropyCostAndGradComplex(U, labels, lopts.K, 0);
        gradst = gradst + gradJE;
    end
    
    % B and U grad
    gradB = 2*beta.*(U-B);
    gradst = gradst + gradB;
    
    Y = dzdy.*reshape(gradst, [1,1,size(gradst)]);
end
end

% -------------------------------------------------------------------------
function[Y] = jointEntropyCostAndGradComplex(U, labels, K, doCost)
% -------------------------------------------------------------------------
srcIds = labels > 0;
tgtIds = labels == 0;
nt = sum(tgtIds);
ns = sum(srcIds);
Ut = U(:,tgtIds);
Us = U(:,srcIds);
srcLabels = labels(srcIds);

unqLabs = unique(srcLabels);
C = length(unqLabs);
d = size(U,1);
gpuMode = isa(U, 'gpuArray') ;

UtUsdot = Ut'*Us; % nt x ns
Utsmax = max(UtUsdot, [], 2);
Pijk = exp(bsxfun(@minus, UtUsdot, Utsmax));
if any(isnan(gather(Pijk)))
    error('Pijk is nan');
end
% Pijk = exp(UtUsdot);
Pijk = bsxfun(@rdivide, Pijk, sum(Pijk,2)); % nt x ns
if gpuMode
    Pij = gpuArray(single(zeros(nt, C)));
else
    Pij = single(zeros(nt, C));
end
onesk = ones(K,1);
for ii = 1:C 
    ids = (ii-1)*K+1 : ii*K;
    Pij(:,ii) = Pijk(:, ids)*onesk;
end

if doCost
    Ph = Pij.*log(Pij);
    Ph(isnan(gather(Ph))) = 0;
    Y = -sum(Ph(:));
else
    % Grad for vi
    if gpuMode
        PijUj = gpuArray(single(zeros(d, nt))); % For sum_k P_ijk*U_jk
        OnePlusLogPijk = gpuArray(single(zeros(nt, ns))); % Repeat Pij and make it [nt x ns]
    else
        PijUj = single(zeros(d, nt)); % For sum_k P_ijk*U_jk
        OnePlusLogPijk = single(zeros(nt, ns)); % Repeat Pij and make it [nt x ns]
    end
    OnePlusLogPij = (1+log(Pij));
    OnePlusLogPij(isinf(OnePlusLogPij)) = 0;
    for ii = 1:C
        ids = (ii-1)*K+1 : ii*K;
        OnePlusLogPijRep = repmat(OnePlusLogPij(:,ii), 1, K);
        OnePlusLogPijk(:, ids) = OnePlusLogPijRep;
        PijUj = PijUj + Us(:,ids)*(Pijk(:,ids).*OnePlusLogPijRep)';
    end
    P1pluslogP = Pij.*OnePlusLogPij;
    PU = (Us*Pijk').*repmat(sum(P1pluslogP,2)',d,1);
    gradUt = PU - PijUj;
    % Grad for Us
    PijkOnePlusLogPijk = Pijk.*OnePlusLogPijk; % nt x ns;
    PijkUt = Ut*PijkOnePlusLogPijk; % d x ns
    PijkPij = bsxfun(@times, Pijk, sum(P1pluslogP, 2));
    PijkPijUt = Ut*PijkPij; % d x ns
    gradUs = PijkPijUt - PijkUt;
    % Total Grad
    if gpuMode
        Y = gpuArray(single(zeros(d, (ns+nt))));
    else
        Y = single(zeros(d, (ns+nt)));
    end
    Y(:,srcIds) = gradUs;
    Y(:,tgtIds) = gradUt;
    if any(isnan(gather(Y(:))))
        error('gardJE is nan');
    end
end
end                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    