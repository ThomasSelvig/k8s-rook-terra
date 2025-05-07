

echo "Access the Kasten UI at: http://localhost:8080/k10/#/"
kubectl -n kasten-io port-forward service/gateway 8080:80
