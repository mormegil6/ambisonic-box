function y = nansum(varargin)
%NANSUM Compatibility shim for MATLAB releases that removed nansum.
%
%   As nanmean: a removed Statistics and Machine Learning Toolbox function,
%   replaced by sum(...,'omitnan'). BAM-Q calls it four times in
%   BAMQ/BAMQ4Public_restruct.m (ITD plus/minus sums), each on a vector.
%
%   sum(...,'omitnan') matches the legacy behaviour for these calls,
%   including returning 0 for an all-NaN input.
%
%   Verified against R2026a Update 4, 2026-08-16.
y = sum(varargin{:}, 'omitnan');
end
