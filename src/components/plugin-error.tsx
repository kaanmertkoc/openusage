import { AlertCircle, RefreshCw } from "lucide-react"
import { Alert, AlertDescription } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"

type PluginErrorProps = {
  message: string
  onRetry?: () => void
}

function formatMessage(message: string) {
  const parts = message.split(/`([^`]+)`/)
  return parts.map((part, index) =>
    index % 2 === 1 ? (
      <code
        key={`code-${index}`}
        className="rounded bg-muted px-1 font-mono text-[0.75rem] leading-tight"
      >
        {part}
      </code>
    ) : (
      part
    )
  )
}

export function PluginError({ message, onRetry }: PluginErrorProps) {
  return (
    <Alert
      variant="destructive"
      className="flex items-center gap-2 [&>svg]:static [&>svg]:translate-y-0 [&>svg~*]:pl-0 [&>svg+div]:translate-y-0"
    >
      <AlertCircle className="h-4 w-4" />
      <AlertDescription className="min-w-0 flex-1 select-text cursor-text">
        {formatMessage(message)}
      </AlertDescription>
      {onRetry && (
        <Button
          type="button"
          variant="outline"
          size="xs"
          onClick={onRetry}
          className="h-6 shrink-0 gap-1 border-destructive/30 text-destructive hover:text-destructive"
        >
          <RefreshCw className="size-3" />
          Retry
        </Button>
      )}
    </Alert>
  )
}
