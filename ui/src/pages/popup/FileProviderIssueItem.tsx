import {
  Alert,
  Box,
  Button,
  Collapse,
  Dialog,
  DialogActions,
  DialogContent,
  DialogContentText,
  DialogTitle,
  Link,
  ListItem,
  ListItemIcon,
  ListItemText,
  Stack,
  TextField,
  Typography,
} from "@mui/material";
import {
  CloudDownload as DownloadIcon,
  CloudUpload as UploadIcon,
  DeleteOutline as DeleteIcon,
  Folder as FolderIcon,
  InsertDriveFile as FileIcon,
  WarningAmber as WarningIcon,
} from "@mui/icons-material";
import { invoke } from "@tauri-apps/api/core";
import { useState } from "react";
import type { FileProviderIssue } from "./types";

interface FileProviderIssueItemProps {
  issue: FileProviderIssue;
  onResolved: () => void;
}

type IssueAction = "save_copy" | "retry" | "discard" | "undo_rename" | "rename" | "auto_fix";

const FORBIDDEN_NAME_CHARS = /[\\/:*?"<>|]/;

function nameError(name: string): string | null {
  const trimmed = name.trim();
  if (trimmed === "" || trimmed === "." || trimmed === "..") {
    return "Enter a valid name";
  }
  if (FORBIDDEN_NAME_CHARS.test(trimmed)) {
    return 'Names cannot contain \\ / : * ? " < > |';
  }
  return null;
}

export default function FileProviderIssueItem({
  issue,
  onResolved,
}: FileProviderIssueItemProps) {
  const [actionsOpen, setActionsOpen] = useState(false);
  const [confirmRestore, setConfirmRestore] = useState(false);
  const [resolvingAction, setResolvingAction] = useState<IssueAction | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [renameOpen, setRenameOpen] = useState(false);
  const [newName, setNewName] = useState(issue.filename);
  const isManagedConflict = issue.source === "upload_conflict";
  const isInvalidName = issue.kind === "invalid_name";
  const newNameError = nameError(newName);
  const canUndoRename =
    !!issue.previous_name && nameError(issue.previous_name) === null;

  const resolve = async (action: IssueAction, name?: string) => {
    setError(null);
    setResolvingAction(action);
    try {
      await invoke("resolve_file_provider_issue", {
        issueId: issue.id,
        action,
        ...(name !== undefined ? { newName: name } : {}),
      });
      onResolved();
    } catch (error) {
      setError(String(error));
    } finally {
      setResolvingAction(null);
    }
  };

  const handleResolve = (action: IssueAction) => {
    if (action === "discard") {
      setConfirmRestore(true);
      return;
    }
    void resolve(action);
  };

  const handleReveal = async (event: React.MouseEvent) => {
    event.preventDefault();
    setError(null);
    try {
      await invoke("reveal_file_provider_issue", { issueId: issue.id });
    } catch (error) {
      setError(String(error));
    }
  };

  const ItemIcon = issue.is_folder ? FolderIcon : FileIcon;
  const OperationIcon = issue.operation === "delete" ? DeleteIcon : issue.operation === "upload" ? UploadIcon : DownloadIcon;
  const busy = resolvingAction !== null;

  return (
    <>
      <ListItem
        alignItems="flex-start"
        sx={{ px: 2, py: 1.25, "&:hover": { bgcolor: "action.hover" } }}
      >
      <ListItemIcon sx={{ minWidth: 40, pt: 0.25 }}>
        <Box sx={{ position: "relative", width: 28, height: 28 }}>
          <ItemIcon sx={{ fontSize: 28, color: "text.secondary" }} />
          <Box
            sx={{
              position: "absolute",
              bottom: -4,
              right: -4,
              bgcolor: "background.paper",
              borderRadius: "50%",
              display: "flex",
              width: 18,
              height: 18,
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <WarningIcon sx={{ fontSize: 14 }} color="warning" />
          </Box>
        </Box>
      </ListItemIcon>
      <ListItemText
        disableTypography
        primary={
          <Stack direction="row" spacing={0.75} alignItems="center">
            <Typography variant="body2" noWrap sx={{ fontWeight: 600, minWidth: 0 }}>
              {issue.filename}
            </Typography>
            <OperationIcon sx={{ fontSize: 15, color: "text.secondary", flexShrink: 0 }} />
          </Stack>
        }
        secondary={
          <Box sx={{ mt: 0.25 }}>
            <Typography variant="caption" color="text.secondary" component="div">
              {issue.message}
            </Typography>
            <Stack
              direction="row"
              spacing={1}
              alignItems="center"
              justifyContent="space-between"
              sx={{ mt: 1 }}
            >
              <Link
                component="button"
                variant="caption"
                color="text.secondary"
                onClick={handleReveal}
                underline="always"
                sx={{ minWidth: 0, overflow: "hidden", textOverflow: "ellipsis" }}
              >
                {issue.drive_name}
              </Link>
              <Button
                size="small"
                variant="contained"
                color="warning"
                disabled={busy}
                onClick={() => setActionsOpen((open) => !open)}
              >
                Resolve
              </Button>
            </Stack>
            <Collapse in={actionsOpen} timeout="auto" unmountOnExit>
              <Box sx={{ mt: 1 }}>
                {isManagedConflict && (
                  <Typography variant="caption" color="text.secondary" component="div" sx={{ mb: 0.75 }}>
                    Save a copy before restoring if you need to preserve your local edits.
                  </Typography>
                )}
                <Stack direction="row" spacing={0.75} useFlexGap flexWrap="wrap">
                  {isManagedConflict && (
                    <Button
                      size="small"
                      variant="contained"
                      disabled={busy}
                      onClick={() => handleResolve("save_copy")}
                    >
                      {resolvingAction === "save_copy" ? "Saving…" : "Save local copy"}
                    </Button>
                  )}
                  {isInvalidName ? (
                    <>
                      {canUndoRename && (
                        <Button
                          size="small"
                          variant="contained"
                          disabled={busy}
                          onClick={() => handleResolve("undo_rename")}
                        >
                          {resolvingAction === "undo_rename" ? "Renaming…" : "Undo rename"}
                        </Button>
                      )}
                      <Button
                        size="small"
                        variant={canUndoRename ? "outlined" : "contained"}
                        disabled={busy}
                        onClick={() => handleResolve("auto_fix")}
                        sx={{ textTransform: "none", maxWidth: "100%" }}
                      >
                        {resolvingAction === "auto_fix"
                          ? "Renaming…"
                          : issue.suggested_name
                            ? `Fix: ${issue.suggested_name}`
                            : "Auto-fix name"}
                      </Button>
                      <Button
                        size="small"
                        variant="outlined"
                        disabled={busy}
                        onClick={() => {
                          setNewName(issue.filename);
                          setRenameOpen(true);
                        }}
                      >
                        {resolvingAction === "rename" ? "Renaming…" : "Rename…"}
                      </Button>
                    </>
                  ) : (
                    <Button
                      size="small"
                      variant="outlined"
                      disabled={busy}
                      onClick={() => handleResolve("retry")}
                    >
                      {resolvingAction === "retry" ? "Retrying…" : `Retry ${issue.operation === "delete" ? "deletion" : issue.operation}`}
                    </Button>
                  )}
                  {isManagedConflict && (
                    <Button
                      size="small"
                      variant="outlined"
                      color="error"
                      disabled={busy}
                      onClick={() => handleResolve("discard")}
                    >
                      {resolvingAction === "discard" ? "Restoring…" : "Restore from Cloudreve"}
                    </Button>
                  )}
                </Stack>
              </Box>
            </Collapse>
            {error && (
              <Alert severity="error" sx={{ mt: 1, py: 0 }}>
                {error}
              </Alert>
            )}
          </Box>
        }
      />
      </ListItem>
      <Dialog open={renameOpen} onClose={() => setRenameOpen(false)}>
        <DialogTitle>Rename item</DialogTitle>
        <DialogContent>
          <TextField
            autoFocus
            fullWidth
            margin="dense"
            size="small"
            label="New name"
            value={newName}
            onChange={(event) => setNewName(event.target.value)}
            error={newNameError !== null}
            helperText={newNameError ?? " "}
            onKeyDown={(event) => {
              if (event.key === "Enter" && newNameError === null) {
                event.preventDefault();
                setRenameOpen(false);
                void resolve("rename", newName.trim());
              }
            }}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setRenameOpen(false)}>Cancel</Button>
          <Button
            variant="contained"
            disabled={newNameError !== null}
            onClick={() => {
              setRenameOpen(false);
              void resolve("rename", newName.trim());
            }}
          >
            Rename
          </Button>
        </DialogActions>
      </Dialog>
      <Dialog open={confirmRestore} onClose={() => setConfirmRestore(false)}>
        <DialogTitle>Restore from Cloudreve?</DialogTitle>
        <DialogContent>
          <DialogContentText>
            Your unsynced changes to “{issue.filename}” will be discarded and replaced
            with the online version.
          </DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setConfirmRestore(false)}>Cancel</Button>
          <Button
            color="error"
            variant="contained"
            onClick={() => {
              setConfirmRestore(false);
              void resolve("discard");
            }}
          >
            Restore
          </Button>
        </DialogActions>
      </Dialog>
    </>
  );
}
