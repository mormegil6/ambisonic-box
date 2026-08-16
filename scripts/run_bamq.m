function run_bamq(pairsFile, bamqDir, outFile)
% Batch BAM-Q + GPSMq over reference/test pairs listed in a TSV.
%
% pairsFile : TSV with columns  label <TAB> refPath <TAB> testPath  (no header)
% bamqDir   : combinedaudioqualitymodel-master
% outFile   : TSV written with label, OPM_fix, binQ, ILDdiff, ITDdiff, IVSdiff, overall
%
% Levels follow Example_combAudioQual.m exactly: GPSMq is fed at +8 dB and
% BAM-Q at -15 dB, because the two models assume different SPL references
% (100 vs 115 dB FS). Reusing one scaling for both would silently misfeed one
% of them, so each gets its own copy of the signals.

% Compatibility shims (nanmean/nansum, removed from modern MATLAB) go on the
% path FIRST so they are visible to the vendored model without editing it.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'matlab-compat'));
addpath(genpath(bamqDir));

fid = fopen(pairsFile, 'r');
C = textscan(fid, '%s%s%s', 'Delimiter', '\t');
fclose(fid);
labels = C{1}; refs = C{2}; tests = C{3};

out = fopen(outFile, 'w');
fprintf(out, 'label\tOPM_fix\tbinQ\tILDdiff\tITDdiff\tIVSdiff\toverall\n');

for k = 1:numel(labels)
    label = labels{k};
    try
        [RefSig, fsRef]   = audioread(refs{k});
        [TestSig, fsTest] = audioread(tests{k});

        if fsRef ~= fsTest
            error('sample rate mismatch: %d vs %d', fsRef, fsTest);
        end
        if size(RefSig,2) ~= 2 || size(TestSig,2) ~= 2
            error('need stereo, got %d / %d channels', size(RefSig,2), size(TestSig,2));
        end
        n = min(size(RefSig,1), size(TestSig,1));
        RefSig = RefSig(1:n,:); TestSig = TestSig(1:n,:);
        fs = fsRef;

        % monaural GPSMq at its own assumed level
        R = RefSig .* 10^(8/20);
        T = TestSig .* 10^(8/20);
        stOut = GPSMqBin(R, T, fs);

        % binaural BAM-Q at ITS level
        R2 = RefSig .* 10^(-15/20);
        T2 = TestSig .* 10^(-15/20);
        [binQ, ILDdiff, ITDdiff, IVSdiff] = BAMQ4Public_restruct(R2, T2, fs);

        obj = combine_binQ_OPM(stOut.OPM_fix(:,1), binQ(:,1));

        fprintf(out, '%s\t%.6f\t%.6f\t%.6g\t%.6g\t%.6g\t%.6f\n', ...
                label, stOut.OPM_fix(1), binQ(1), ILDdiff(1), ITDdiff(1), IVSdiff(1), obj(1));
        fprintf('done %s  OPM_fix=%.3f binQ=%.3f overall=%.4f\n', ...
                label, stOut.OPM_fix(1), binQ(1), obj(1));
    catch err
        fprintf(out, '%s\tERR\tERR\tERR\tERR\tERR\tERR\n', label);
        fprintf('FAIL %s: %s\n', label, err.message);
    end
end
fclose(out);
end
