function [u, g, w, We, d] = triinvx(s, p, beta, varargin)
%
% TRIINVX   Inverts surface displacements for slip on triangular mesh in Cartesian space.
%    TRIINV(S, T, BETA) inverts the displacements/velocities contained 
%    in the structure S for slip on the triangular dislocation mesh defined
%    in the file T, which can be in .mat or .msh format (see below), subject to the
%    Laplacian smoothing constraint whose strength is defined as BETA. 
%
%    TRIINV(..., 'partials', G) enables specification of a pre-calculated matrix, 
%    G, of partial derivatives relating slip on triangular dislocation elements to 
%    displacement at observation coordinates. G should be 3*nObs-by-3*nTri.
%
%    TRIINV(..., 'lock', EDGES) subjects the inversion to locking (zero slip) 
%    constraints on the updip, downdip, and/or lateral edges of the triangular mesh.  
%    EDGES is a 3-column array with non-zero values corresponding to the edges(s) 
%    to be locked. For example, EDGES = [1 0 1] imposes no-slip conditions on the updip
%    and lateral edges of the fault (columns 1 and 3, respectively), but not on the 
%    downdip edge (column 2). For structures T that contain multiple distinct faults
%    (i.e., numel(T.nEl) > 1), specify EDGES as a single row to apply the constraints to 
%    all faults, or include a unique row for each fault. 
%
%    TRIINV(..., 'dcomp', COMPONENTS) allows specification of which components of the 
%    displacement (velocity) observations to use. COMPONENTS is a 3-element vector with
%    non-zero entries corresponding to the components to consider as observations in the 
%    inversion. For example, to use only vertical displacement data, specify:
%    COMPONENTS = [0 0 1]. The default behavior is COMPONENTS = [1 1 1] so that the 
%    X, Y, and Z components are all considered as constraining data in the inversion. 
%
%    TRIINV(..., 'nneg', NONNEG) allows specification of which components of the 
%    slip distribution should be restricted to be positive only. NONNEG should be a 
%    2-element vector with a 0 to place no constraint on the sign of slip and 1 to 
%    constrain slip in that direction to be positive. The 2 elements correspond to the
%    strike and dip/tensile direction, respectively. For example, to constrain dip 
%    slip only to be non-negative, specify NONNEG = [0 1]; 
%
%    *** Important notes about the KERNEL argument: ***
%    If you specify a string for KERNEL, the program will check for its existence, and 
%    load it if it exists. If not, the elastic partials will be calculated and saved to
%    KERNEL. No internal checks are made to assure that an existing KERNEL corresponds 
%    to the present station-source geometry, except that the inversion will fail if the 
%    loaded kernel does not have the same dimensions as the present configuration 
%    of S and T.  To assure calculation of a "fresh" kernel, either delete the
%    existing kernel or provide a unique file name.
%
%    *** Notes about input argument T: ***
%    T can either be the path to a .msh file as written by the open-source meshing 
%    program Gmsh, or a .mat file containing two variables "c" and "v".  c is an n-by-3 
%    array whose columns contain the X, Y, Z coordinates of the n nodes in a triangular
%    mesh.  Z coordinates should be negative, i.e. a depth of 15 km would be given as -15.
%    v is an m-by-3 array containing the indexes of the nodes that comprise each triangle.
%    For example, if element 1 of the mesh is made up of nodes 10, 17, and 103, the first
%    line of V should be [10, 17, 103].  
%
%    U = TRIINV(...) returns the estimated slip (rate) to vector U.  U is structured
%    so that strike, dip, and tensile slip estimates are stacked, i.e. 
%         U = [Us1, Ud1, Ut1, Us2, Ud2, Ut2, ..., Usm, Udm, Utm]';

% Parse optional inputs 
if nargin > 3
   for i = 1:2:numel(varargin)
      if startsWith(varargin{i}, 'partials')
         g = varargin{i+1};
      elseif startsWith(varargin{i}, 'lock')
         Command.triEdge = varargin{i+1};
      elseif startsWith(varargin{i}, 'dcomp')
         dcomp = varargin{i+1};
      elseif startsWith(varargin{i}, 'nneg')
         nneg = varargin{i+1};
      end
   end
end

% Check station structure to make sure z coordinates exist; assume surface if not specified
if ~isfield(s, 'z')
   s.z                              = 0*s.x;
end

% Add template vertical velocity and uncertainty, if need be
if ~isfield(s, 'upVel')
   s.upVel                          = 0*s.eastVel;
end
if ~isfield(s, 'upSig')
   s.upSig                          = ones(numsta, 1);
end

% Station count
numsta = numel(s.x);

if ischar(p) % if the triangular mesh was specified as a file...
   % load the patch file...
   p                                = ReadPatches(p);
else
   % Check to see that the necessary fields were provided
   if sum(isfield(p, {'c', 'v', 'nEl', 'nc'})) ~= 4
      error('Missing one of more required fields in patch structure.', 'missingPatchf');
   end
end

% Process patch coordinates
p                                   = PatchCoordsx(p);
% Identify dipping and vertical elements
tz                                  = 3*ones(p.nEl, 1); % By default, all are vertical (will zero out second component of slip)
tz(abs(90-p.dip) > 1)               = 2; % Dipping elements are changed

% Check the length of beta and repeat if necessary
if numel(beta) ~= numel(p.nEl)
   beta                             = repmat(beta, numel(p.nEl), 1);
end

% Check for existing kernel
if ~exist('g', 'var')
   % Calculate the triangular partials
   g                                = GetTriCombinedPartialsx(p, s, [1 0]);
end

% Adjust triangular partials
triS                                = [1:length(tz)]'; % All include strike
triD                                = find(tz(:) == 2); % Find those with dip-slip
triT                                = find(tz(:) == 3); % Find those with tensile slip
colkeep                             = setdiff(1:size(g, 2), [3*triD-0; 3*triT-1]);
gt                                  = g(:, colkeep); % eliminate the partials that equal zero

% Determine which rows of partial derivative matrix to keep.
% These rows correspond to displacement components that are being considered.

% dcomp is the optional variable that controls this, and it should be a 
% 3-element vector with non-zero entries for those components that should be used.
if exist('dcomp', 'var')
   dcomp                            = repmat(dcomp(:), numsta, 1);
   rowkeep                          = find(dcomp ~= 0);
else
   rowkeep                          = 1:3*numel(s.x);
end   

gt                                  = gt(rowkeep, :);

% Lock edges?
if ~exist('Command.triEdge', 'var')
   Command.triEdge                  = 0;
end

if sum(Command.triEdge) ~= 0
   Ztri                             = ZeroTriEdges(p, Command);
else
   Ztri                             = zeros(0, size(gt, 2));
end

% Spatial smoothing
if sum(beta)  
   % Find neighbors
   share = SideShare(p.v);

   % Make the smoothing matrix
   w = MakeTriSmoothAlt(share);
   w = w(colkeep, :);
   w = w(:, colkeep);
else
   w                                = zeros(0, 3*size(p.v, 1));
end

% Weighting matrix
we                                  = stack3(1./[s.eastSig, s.northSig, s.upSig].^2);
we                                  = we(rowkeep);
we                                  = [we ; beta.*ones(size(w, 1), 1)]; % add the triangular smoothing vector
we                                  = [we ; 1e10*ones(size(Ztri, 1), 1)]; % add the zero edge vector
We                                  = diag(we); % assemble into a matrix

% Assemble the Jacobian...
G                                   = [gt; w; Ztri];
% ...and the data vector
d                                   = stack3([s.eastVel, s.northVel, s.upVel]);
d                                   = d(rowkeep);
d                                   = [d; zeros(size(w, 1), 1); zeros(size(Ztri, 1), 1)];


% Check inversion type
if ~exist('nneg', 'var')
   nneg = 0;
end

if sum(nneg) == 0
   % Backslash inversion
   u                                   = (G'*We*G)\(G'*We*d);
else
   % Use non-negative solver
   options = optimoptions('lsqlin', 'tolfun', 1e-25, 'maxiter', 1e5, 'tolpcg', 1e-3, 'PrecondBandWidth', Inf);
   % Set bounds on sign of slip components
   slipbounds = [-Inf Inf; 0 Inf];
   slipboundss = slipbounds(double(nneg(1) ~= 0) + 1, :);
   slipboundsd = slipbounds(double(nneg(2) ~= 0) + 1, :);
   u = lsqlin(G'*We*G, G'*We*d, [], [], [], [], repmat([slipboundss(1); slipboundsd(1)], size(G, 2)/2, 1), repmat([slipboundss(2); slipboundsd(2)], size(G, 2)/2, 1), [], options);
end


% Pad the estimated slip with zeros, corresponding to slip components that were not estimated
U                                   = zeros(3*numel(p.xc), 1);
U(colkeep)                          = u;
u                                   = U;
