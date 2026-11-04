import { Alert, Box, Button, CircularProgress, Container, IconButton, InputAdornment, Snackbar, Typography } from "@mui/material";
import CloseIcon from "@mui/icons-material/Close";
import { openUrl } from "@tauri-apps/plugin-opener";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { invoke } from '@tauri-apps/api/core';
import confetti from "canvas-confetti";
import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { useParams } from "react-router-dom";
import defaultLogo from "../assets/cloudreve.svg";
import { FilledTextField } from "../common/StyledComponent";
import { fetchSiteIcon, isValidUrl } from "../utils/manifest";
import { generatePKCEPair, randomCryptoString } from "../utils/pkce";
import {
  exchangeTokens,
  isValidationError,
  validateSiteVersion,
  type TokenResponse,
} from "../utils/siteValidation";
import { listen } from '@tauri-apps/api/event';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { platform } from '@tauri-apps/plugin-os';
import { CALLBACK_PATH, CLIENT_ID, SCOPES } from "../utils/constants";

type PageState = "url_input" | "waiting" | "final_setup" | "setting_up" | "finder_setup" | "success";

interface OAuthCallbackData {
  code: string;
  state: string;
  name: string;
  path: string;
  user_id?: string;
}

// Store PKCE data for use after OAuth redirect
export interface PKCESession {
  codeVerifier: string;
  codeChallenge: string;
  siteUrl: string;
  siteVersion: string;
  siteIcon?: string;
  state?: string;
  callbackData?: OAuthCallbackData;
}

interface AddDriveProps {
  mode?: "add" | "reauthorize";
}

function parseDeeplinkUrl(url: string): OAuthCallbackData | null {
  try {
    // Handle custom protocol: cloudreve://callback/desktop?code=xxx&state=xxx
    const urlObj = new URL(url);
    const code = urlObj.searchParams.get("code");
    const state = urlObj.searchParams.get("state");
    const name = urlObj.searchParams.get("name") || "";
    const path = urlObj.searchParams.get("path") || "";
    const user_id = urlObj.searchParams.get("user_id") || "";
    if (code && state) {
      return { code, state, name, path, user_id };
    }
    return null;
  } catch {
    return null;
  }
}

function buildAuthorizeUrl(siteUrl: string, codeChallenge: string, state: string): string {
  const url = new URL("/session/authorize", siteUrl);
  const params = {
    response_type: "code",
    client_id: CLIENT_ID,
    scope: SCOPES,
    redirect_uri: CALLBACK_PATH,
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
    state: state,
  };
  // Use encodeURIComponent to encode spaces as %20 instead of +
  url.search = Object.entries(params)
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
    .join("&");
  return url.toString();
}

export default function AddDrive({ mode = "add" }: AddDriveProps) {
  const { t } = useTranslation();
  const { driveId, siteUrl: encodedSiteUrl, driveName: driveNameQuery } = useParams<{ driveId?: string; siteUrl?: string, driveName: string }>();
  const isReauthorize = mode === "reauthorize" && driveId && encodedSiteUrl;
  const decodedSiteUrl = encodedSiteUrl ? decodeURIComponent(encodedSiteUrl) : "";
  // macOS uses the native File Provider integration (Finder location) instead
  // of syncing to a user-chosen local folder, so no local path is needed.
  const [isMacOS] = useState(() => platform() === "macos");

  const [siteUrl, setSiteUrl] = useState(isReauthorize ? decodedSiteUrl : "");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [savedDriveId, setSavedDriveId] = useState<string | null>(null);
  const [finderPath, setFinderPath] = useState<string | null>(null);
  const [finderBusy, setFinderBusy] = useState(false);
  const finderCheckInFlight = useRef(false);
  const [snackbarOpen, setSnackbarOpen] = useState(false);
  const [logo, setLogo] = useState(defaultLogo);
  const [authorizeUrl, setAuthorizeUrl] = useState<string | null>(null);
  const [pageState, setPageState] = useState<PageState>(isReauthorize ? "url_input" : "url_input");
  const [localPath, setLocalPath] = useState("");
  const [folderNotEmpty, setFolderNotEmpty] = useState(false);
  const [driveName, setDriveName] = useState(driveNameQuery ? decodeURIComponent(driveNameQuery) : "");
  const lastFetchedUrl = useRef<string>("");
  const currentIconUrl = useRef<string | undefined>(undefined);
  const pkceSessionRef = useRef<PKCESession | null>(null);
  const hasInitialized = useRef(false);

  // Listen for deeplink events from OAuth callback
  useEffect(() => {
    let unlisten: () => void;
    listen<string>('deeplink', (event) => {
      console.log("Received deeplink event:", event.payload);

      const callbackData = parseDeeplinkUrl(event.payload);
      if (!callbackData) {
        console.error("Failed to parse deeplink URL:", event.payload);
        return;
      }

      // Verify state matches current session
      if (!pkceSessionRef.current || callbackData.state !== pkceSessionRef.current.state) {
        console.error("State mismatch or no active session", pkceSessionRef.current, callbackData);
        setError(t("addDrive.errors.stateMismatch"));
        setSnackbarOpen(true);
        return;
      }

      // Store the auth code in the session
      pkceSessionRef.current.callbackData = callbackData;

      // Transition to final setup page
      if (callbackData.name) {
        setDriveName(callbackData.name);
      }
      setPageState("final_setup");
    }).then((fn) => {
      unlisten = fn;
    });

    return () => {
      if (unlisten) {
        unlisten();
      }
    };
  }, [t]);

  // Fetch site icon when URL changes and is valid
  const handleUrlBlur = () => {
    const trimmedUrl = siteUrl.trim();
    if (!isValidUrl(trimmedUrl) || trimmedUrl === lastFetchedUrl.current) {
      return;
    }

    lastFetchedUrl.current = trimmedUrl;

    fetchSiteIcon(trimmedUrl)
      .then((iconUrl) => {
        if (iconUrl) {
          // Preload the image to ensure it loads successfully
          const img = new Image();
          img.onload = () => {
            setLogo(iconUrl);
            currentIconUrl.current = iconUrl;
          };
          img.onerror = () => {
            console.error("Failed to load site icon:", iconUrl);
            currentIconUrl.current = undefined;
          };
          img.src = iconUrl;
        }
      })
      .catch((err) => {
        console.error("Failed to fetch manifest:", err);
        currentIconUrl.current = undefined;
      });
  };

  // Reset logo when URL is cleared or becomes invalid
  useEffect(() => {
    if (!siteUrl.trim() || !isValidUrl(siteUrl.trim())) {
      setLogo(defaultLogo);
      lastFetchedUrl.current = "";
      currentIconUrl.current = undefined;
    }
  }, [siteUrl]);

  // Shared authorization logic
  const startAuthorization = useCallback(async (urlToAuthorize: string) => {
    setLoading(true);
    setSnackbarOpen(false);

    try {
      // Validate site version first
      const version = await validateSiteVersion(urlToAuthorize);
      console.log("Site version:", version);

      // Generate PKCE pair
      const { codeVerifier, codeChallenge } = await generatePKCEPair();
      // Add "reauthorize:" prefix to state when in reauthorize mode
      const stateValue = isReauthorize
        ? `reauthorize:${randomCryptoString(32)}`
        : randomCryptoString(32);

      // Store PKCE session data for use after OAuth redirect
      pkceSessionRef.current = {
        codeVerifier,
        codeChallenge,
        siteUrl: urlToAuthorize.trim(),
        siteVersion: version,
        siteIcon: currentIconUrl.current,
        state: stateValue,
      };

      // Build and open the authorization URL
      const authUrl = buildAuthorizeUrl(urlToAuthorize.trim(), codeChallenge, stateValue);
      setAuthorizeUrl(authUrl);
      setPageState("waiting");
      await openUrl(authUrl);
    } catch (error) {
      if (isValidationError(error)) {
        setError(t(`addDrive.errors.${error.type}`, error.params));
      } else {
        const message = error instanceof Error ? error.message : String(error);
        setError(t("addDrive.errors.connectionFailed", { message }));
      }
      setSnackbarOpen(true);
    } finally {
      setLoading(false);
    }
  }, [t, isReauthorize]);

  // Auto-start authorization flow when in reauthorize mode
  useEffect(() => {
    if (isReauthorize && !hasInitialized.current) {
      hasInitialized.current = true;
      // Fetch site icon for the reauthorize URL
      fetchSiteIcon(decodedSiteUrl)
        .then((iconUrl) => {
          if (iconUrl) {
            const img = new Image();
            img.onload = () => {
              setLogo(iconUrl);
              currentIconUrl.current = iconUrl;
            };
            img.src = iconUrl;
          }
        })
        .catch((err) => {
          console.error("Failed to fetch manifest:", err);
        });

      // Auto-start the authorization flow
      startAuthorization(decodedSiteUrl);
    }
  }, [isReauthorize, decodedSiteUrl, startAuthorization]);

  // Trigger confetti effect when entering success state
  useEffect(() => {
    if (pageState === "success") {
      confetti({
        particleCount: 100,
        spread: 70,
        origin: { y: 0.6 },
      });
    }
  }, [pageState]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    await startAuthorization(siteUrl);
  };

  const handleOpenAuthorizeUrl = async () => {
    if (authorizeUrl) {
      await openUrl(authorizeUrl);
    }
  };

  const handleBack = () => {
    setAuthorizeUrl(null);
    setPageState("url_input");
    setLocalPath("");
    setFolderNotEmpty(false);
    pkceSessionRef.current = null;
  };

  const handleCloseSnackbar = () => {
    setSnackbarOpen(false);
  };

  const checkDirEmpty = async (path: string) => {
    try {
      const empty = await invoke<boolean>('is_dir_empty', { path });
      setFolderNotEmpty(!empty);
    } catch {
      setFolderNotEmpty(false);
    }
  };

  const handleBrowseFolder = async () => {
    const selected = await openDialog({
      directory: true,
      multiple: false,
      title: t("addDrive.selectFolder"),
    });
    if (selected) {
      setLocalPath(selected);
      await checkDirEmpty(selected);
    }
  };

  const handleFinish = async (e: React.FormEvent) => {
    e.preventDefault();
    setPageState("setting_up");
    // TODO: Call backend to complete drive setup

    let tokens: TokenResponse;
    try {
      tokens = await exchangeTokens(
        pkceSessionRef.current!.siteUrl,
        pkceSessionRef.current!.callbackData!.code,
        pkceSessionRef.current!.codeVerifier
      );
    } catch (error) {
      if (isValidationError(error)) {
        setError(t(`addDrive.errors.${error.type}`, error.params));
      } else {
        const message = error instanceof Error ? error.message : String(error);
        setError(t("addDrive.errors.connectionFailed", { message }));
      }
      setPageState("final_setup");
      setSnackbarOpen(true);
      return;
    }

    // Clean the site URL to only include origin (no path or trailing slash)
    const cleanSiteUrl = new URL(pkceSessionRef.current!.siteUrl).origin;

    try {
      const savedId = await invoke<string>('add_drive', {
        config: {
          site_url: cleanSiteUrl,
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          access_token_expires: tokens.expires_in,
          refresh_token_expires: tokens.refresh_token_expires_in,
          drive_name: driveName,
          local_path: localPath,
          remote_path: pkceSessionRef.current!.callbackData!.path,
          user_id: pkceSessionRef.current!.callbackData!.user_id || "",
          drive_id: isReauthorize ? driveId : undefined,
        }
      });
      setSavedDriveId(savedId);
      if (isMacOS) {
        setPageState("finder_setup");
        await connectFinder(savedId);
      } else {
        setPageState("success");
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setError(t("addDrive.errors.addDriveFailed", { message }));
      setPageState("url_input");
      setSnackbarOpen(true);
    }
  }

  const connectFinder = async (id: string) => {
    setFinderBusy(true);
    setError("");
    try {
      const path = await invoke<string>("complete_finder_setup", { driveId: id, driveName });
      setFinderPath(path);
      setPageState("finder_setup");
    } catch (error) {
      setError(String(error));
      setPageState("finder_setup");
    } finally { setFinderBusy(false); }
  };

  // Resume automatically after the user approves the native Finder/TCC UI.
  // Only one check may await a system dialog at a time.
  useEffect(() => {
    if (pageState !== "finder_setup" || !savedDriveId || !finderPath || finderBusy) return;
    let cancelled = false;
    const verify = async () => {
      if (finderCheckInFlight.current) return;
      finderCheckInFlight.current = true;
      try {
        await invoke("verify_finder_setup", { driveId: savedDriveId });
        if (!cancelled) { setError(""); setPageState("success"); }
      } catch (error) {
        if (!cancelled) setError(String(error));
      } finally { finderCheckInFlight.current = false; }
    };
    void verify();
    const timer = setInterval(() => void verify(), 3000);
    return () => { cancelled = true; clearInterval(timer); };
  }, [pageState, savedDriveId, finderPath, finderBusy]);

  const handleOpenDriveAndClose = async () => {
    try {
      if (isMacOS) {
        if (!finderPath) throw new Error("Finder location is not ready yet");
        await invoke("show_file_in_explorer", { path: finderPath });
      } else {
        // The opener plugin is intentionally scoped to $HOME, while Windows
        // sync roots can live on any drive (for example E:\\Cloudreve). Use
        // the native command so valid non-home paths are not rejected.
        await invoke("show_file_in_explorer", { path: localPath });
      }
    } catch (openError) {
      setError(String(openError));
      setSnackbarOpen(true);
      return;
    }
    await getCurrentWindow().destroy();
  }

  return (
    <Container
      maxWidth="sm"
      sx={{
        bgcolor: "background.default",
        color: "text.primary",
        height: "100vh",
        overflowY: "auto",
        position: "relative",
      }}
    >
      <Box
        sx={{
          minHeight: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          alignItems: "center",
          py: 4,
        }}
      >
        <Box
          sx={{
            position: "absolute",
            top: 0,
            left: 0,
            right: 0,
            height: 32,
            display: "flex",
            alignItems: "center",
            justifyContent: "flex-end",
            px: 0.5,
            zIndex: 1,
          }}
        >
          <Box
            data-tauri-drag-region
            sx={{ position: "absolute", inset: 0 }}
          />
          {!isMacOS && (
            <IconButton
              size="small"
              onClick={() => getCurrentWindow().destroy()}
              sx={{ WebkitAppRegion: "no-drag", appRegion: "no-drag", zIndex: 1 }}
            >
              <CloseIcon fontSize="small" />
            </IconButton>
          )}
        </Box>
        <Box
          sx={{
            p: 4,
            py: 2,
            width: "100%",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            gap: 1,
            borderRadius: 3,
          }}
        >
          {pageState !== "setting_up" && pageState !== "success" && pageState !== "finder_setup" && <Box
            component="img"
            src={logo}
            alt="Cloudreve"
            sx={{
              width: 120,
              height: "auto",
              mb: 2,
            }}
          />}

          {pageState === "success" ? (
            // Success state - all done!
            <>
              <Typography
                variant="h1"
                sx={{ fontSize: 64, mt: 2 }}
              >
                🎉
              </Typography>
              <Typography
                sx={{ mt: 2 }}
                variant="h5"
                component="h1"
                fontWeight={500}
                textAlign="center"
              >
                {isReauthorize ? t("addDrive.reauthorizeSuccessTitle") : t("addDrive.successTitle")}
              </Typography>

              {isMacOS && <Typography variant="body2" color="text.secondary" textAlign="center">
                {t("addDrive.finderReady", "Your Finder location is ready. Cloudreve is checking for changes. Follow progress in the menu bar. Use Keep Downloaded in Finder for files you need offline.")}
              </Typography>}
              <Box
                sx={{
                  width: "100%",
                  display: "flex",
                  flexDirection: "column",
                  gap: 2,
                  mt: 2,
                }}
              >
                {isReauthorize ? (
                  <Button
                    variant="contained"
                    size="large"
                    fullWidth
                    onClick={() => getCurrentWindow().destroy()}
                  >
                    {t("addDrive.close")}
                  </Button>
                ) : (
                  <Button
                    variant="contained"
                    size="large"
                    fullWidth
                    onClick={handleOpenDriveAndClose}
                  >
                    {t("addDrive.openDrive", { name: driveName })}
                  </Button>
                )}
              </Box>
            </>
          ) : pageState === "finder_setup" ? (
            <>
              <Typography variant="h5" component="h1">{t("addDrive.finderTitle", "Connect Finder")}</Typography>
              <Typography variant="body2" color="text.secondary" textAlign="center">
                {t("addDrive.finderDescription", "Your account is saved. Finder opens your new drive automatically. Choose Allow or Enable if macOS asks. We’ll check access and finish setup as soon as approval is complete.")}
              </Typography>
              {error && <Alert severity="warning" sx={{ width: "100%", boxSizing: "border-box" }}>{error}</Alert>}
              {!finderPath && error && <FilledTextField fullWidth label={t("addDrive.localDriveName")} value={driveName}
                disabled={finderBusy} onChange={(event) => setDriveName(event.target.value)} />}
              <Button fullWidth variant="contained" loading={finderBusy} disabled={!savedDriveId || !driveName.trim()}
                onClick={() => savedDriveId && connectFinder(savedDriveId)}>
                {finderPath ? t("addDrive.openFinderAgain", "Open Finder again") : t("addDrive.retryFinder", "Connect Finder / Retry")}
              </Button>
              {finderPath && <Typography variant="body2" color="text.secondary">
                {t("addDrive.waitingApproval", "Waiting for Finder approval and file access… You can return here after approving the native prompt.")}
              </Typography>}
              <Button onClick={async () => {
                try { await invoke("open_finder_setup_settings"); }
                catch (error) { setError(String(error)); }
              }}>{t("addDrive.openSystemSettings", "Open System Settings")}</Button>
              {error && <Typography variant="caption" color="text.secondary">
                {t("addDrive.permissionsHelp", "If needed: General → Login Items & Extensions → File Providers enables Cloudreve. Privacy & Security → Files and Folders controls file access. Full Disk Access and Accessibility are not required for this setup.")}
              </Typography>}
              <Button onClick={() => getCurrentWindow().destroy()} disabled={finderBusy}>
                {t("addDrive.finishLater", "Finish later in Settings")}
              </Button>
            </>
          ) : pageState === "setting_up" ? (
            // Setting up state - loading indicator
            <>
              <CircularProgress size={48} sx={{ mt: 2 }} />
              <Typography
                sx={{ mt: 2 }}
                variant="h6"
                component="h1"
                fontWeight={500}
                textAlign="center"
              >
                {t("addDrive.settingUp")}
              </Typography>
            </>
          ) : pageState === "final_setup" ? (
            // Final setup state - local path input (hidden in reauthorize mode)
            <>
              <Typography
                sx={{ mt: 2 }}
                variant="h5"
                component="h1"
                fontWeight={500}
              >
                {isReauthorize ? t("addDrive.reauthorizeTitle") : t("addDrive.finalSetupTitle")}
              </Typography>

              <Typography
                variant="body2"
                color="text.secondary"
                textAlign="center"
              >
                {isReauthorize ? t("addDrive.reauthorizeDescription") : isMacOS
                  ? t("addDrive.finderNameDescription", "Choose a name for your drive in Finder. Next, macOS will ask for any access it needs.")
                  : t("addDrive.finalSetupDescription")}
              </Typography>

              <Box
                component="form"
                onSubmit={handleFinish}
                sx={{
                  width: "100%",
                  display: "flex",
                  flexDirection: "column",
                  gap: 2,
                  mt: 2,
                }}
              >
                <FilledTextField
                  disabled={mode === "reauthorize"}
                  fullWidth
                  autoComplete="off"
                  label={t("addDrive.localDriveName")}
                  value={driveName}
                  onChange={(e) => setDriveName(e.target.value)}
                  variant="filled"
                  required
                />

                {!isReauthorize && !isMacOS && (
                  <>
                    <FilledTextField
                      fullWidth
                      autoComplete="off"
                      label={t("addDrive.localPath")}
                      placeholder={t("addDrive.localPathPlaceholder")}
                      value={localPath}
                      onChange={(e) => {
                        setLocalPath(e.target.value);
                        setFolderNotEmpty(false);
                      }}
                      onBlur={() => localPath && checkDirEmpty(localPath)}
                      variant="filled"
                      required
                      slotProps={{
                        input: {
                          endAdornment: (
                            <InputAdornment position="end">
                              <Button
                                onClick={handleBrowseFolder}
                                size="small"
                              >
                                {t("addDrive.browse")}
                              </Button>
                            </InputAdornment>
                          ),
                        },
                      }}
                    />
                    {folderNotEmpty && (
                      <Alert severity="info" sx={{ mt: -1 }}>
                        {t(
                          "addDrive.folderNotEmptyWillSync",
                          "This folder already has files. Existing local content will be merged into the remote drive. Same-name files with matching hashes will be treated as already synced."
                        )}
                      </Alert>
                    )}
                  </>
                )}

                <Button
                  type="submit"
                  variant="contained"
                  size="large"
                  fullWidth
                >
                  {isReauthorize ? t("addDrive.reauthorizeConfirm") : t("addDrive.finish")}
                </Button>

                <Button
                  variant="text"
                  size="large"
                  fullWidth
                  onClick={handleBack}
                >
                  {t("addDrive.back")}
                </Button>
              </Box>
            </>
          ) : pageState === "waiting" ? (
            // Waiting for sign-in state
            <>
              <Typography
                sx={{ mt: 2 }}
                variant="h5"
                component="h1"
                fontWeight={500}
              >
                {t("addDrive.waitingTitle")}
              </Typography>

              <Typography
                variant="body2"
                color="text.secondary"
                textAlign="center"
              >
                {t("addDrive.waitingDescription")}
              </Typography>

              <Box
                sx={{
                  width: "100%",
                  display: "flex",
                  flexDirection: "column",
                  gap: 2,
                  mt: 2,
                }}
              >
                <Button
                  variant="contained"
                  size="large"
                  fullWidth
                  onClick={handleOpenAuthorizeUrl}
                >
                  {t("addDrive.reopenBrowser")}
                </Button>

                <Button
                  variant="text"
                  size="large"
                  fullWidth
                  onClick={handleBack}
                >
                  {t("addDrive.back")}
                </Button>
              </Box>
            </>
          ) : (
            // Initial URL input state
            <>
              <Typography
                sx={{ mt: 2 }}
                variant="h5"
                component="h1"
                fontWeight={500}
              >
                {t("addDrive.title")}
              </Typography>

              <Typography
                variant="body2"
                color="text.secondary"
                textAlign="center"
              >
                {t("addDrive.description")}
              </Typography>

              <Box
                component="form"
                onSubmit={handleSubmit}
                sx={{
                  width: "100%",
                  display: "flex",
                  flexDirection: "column",
                  gap: 2,
                  mt: 2,
                }}
              >
                <FilledTextField
                  fullWidth
                  autoComplete="off"
                  slotProps={{
                    input: {
                      readOnly: loading,
                    },
                  }}
                  label={t("addDrive.siteUrl")}
                  placeholder={t("addDrive.siteUrlPlaceholder")}
                  value={siteUrl}
                  onChange={(e) => setSiteUrl(e.target.value)}
                  onBlur={handleUrlBlur}
                  variant="filled"
                  type="url"
                  required
                />

                <Button
                  type="submit"
                  variant="contained"
                  size="large"
                  loading={loading}
                  fullWidth
                >
                  {t("addDrive.connect")}
                </Button>
              </Box>
            </>
          )}
        </Box>
      </Box>
      <Snackbar
        open={snackbarOpen}
        autoHideDuration={6000}
        onClose={handleCloseSnackbar}
        message={error}
      />
    </Container>
  );
}
