function y = nanmean(varargin)
%NANMEAN Compatibility shim for MATLAB releases that removed nanmean.
%
%   nanmean was a Statistics and Machine Learning Toolbox function,
%   deprecated in favour of mean(...,'omitnan') and since removed. The
%   BAM-Q / GPSMq model (Flessner et al. 2019) predates the removal and
%   calls it in GPSMq/mreGPSMq/BE/frommat2single_STint_mreGPSMq_binaural_v2.m
%   as nanmean(X,1).
%
%   Shimmed rather than installing the toolbox, and rather than editing the
%   vendored model: mean(...,'omitnan') is the documented replacement with
%   identical semantics, including returning NaN when every element is NaN.
%
%   Verified against R2026a Update 4, 2026-08-16.
y = mean(varargin{:}, 'omitnan');
end
