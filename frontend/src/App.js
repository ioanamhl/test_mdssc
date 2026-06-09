import React, { useState, useEffect } from 'react';
import './App.css';

const API = process.env.REACT_APP_API_URL || 'http://localhost:3001';

function App() {
  const [todos, setTodos] = useState([]);
  const [text, setText] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    fetch(`${API}/api/todos`)
      .then(r => r.json())
      .then(setTodos)
      .catch(() => setError('Could not connect to backend'));
  }, []);

  async function addTodo(e) {
    e.preventDefault();
    if (!text.trim()) return;
    const res = await fetch(`${API}/api/todos`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text }),
    });
    const todo = await res.json();
    setTodos(prev => [...prev, todo]);
    setText('');
  }

  async function toggleTodo(id, done) {
    const res = await fetch(`${API}/api/todos/${id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ done: !done }),
    });
    const updated = await res.json();
    setTodos(prev => prev.map(t => (t.id === id ? updated : t)));
  }

  async function deleteTodo(id) {
    await fetch(`${API}/api/todos/${id}`, { method: 'DELETE' });
    setTodos(prev => prev.filter(t => t.id !== id));
  }

  return (
    <div className="app">
      <h1>Todo App</h1>
      {error && <p className="error">{error}</p>}
      <form onSubmit={addTodo} className="form">
        <input
          value={text}
          onChange={e => setText(e.target.value)}
          placeholder="Add a new task..."
        />
        <button type="submit">Add</button>
      </form>
      <ul className="list">
        {todos.map(todo => (
          <li key={todo.id} className={todo.done ? 'done' : ''}>
            <span onClick={() => toggleTodo(todo.id, todo.done)}>{todo.text}</span>
            <button onClick={() => deleteTodo(todo.id)}>✕</button>
          </li>
        ))}
      </ul>
      <p className="count">{todos.filter(t => !t.done).length} task(s) remaining</p>
    </div>
  );
}

export default App;
